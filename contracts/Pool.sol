// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.7.5;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./YieldMath.sol";
import "./helpers/Delegable.sol";
import "./helpers/SafeCast.sol";
import "./helpers/ERC20Permit.sol";
import "./interfaces/IFYDai.sol";
import "./interfaces/IPool.sol";


/// @dev The Pool contract exchanges Dai for fyDai at a price defined by a specific formula.
contract Pool is IPool, Delegable(), ERC20Permit {
    using SafeMath for uint256;

    event Trade(uint256 maturity, address indexed from, address indexed to, int256 daiTokens, int256 fyDaiTokens);
    event Liquidity(uint256 maturity, address indexed from, address indexed to, int256 daiTokens, int256 fyDaiTokens, int256 poolTokens);

    int128 constant public k = int128(uint256((1 << 64)) / 126144000); // 1 / Seconds in 4 years, in 64.64
    int128 constant public g1 = int128(uint256((950 << 64)) / 1000); // To be used when selling Dai to the pool. All constants are `ufixed`, to divide them they must be converted to uint256
    int128 constant public g2 = int128(uint256((1000 << 64)) / 950); // To be used when selling fyDai to the pool. All constants are `ufixed`, to divide them they must be converted to uint256
    uint128 immutable public maturity;

    IERC20 public override dai;
    IFYDai public override fyDai;

    constructor(address dai_, address fyDai_, string memory name_, string memory symbol_)
        public
        ERC20Permit(name_, symbol_)
    {
        dai = IERC20(dai_);
        fyDai = IFYDai(fyDai_);

        maturity = toUint128(fyDai.maturity());
    }

    /// @dev Trading can only be done before maturity
    modifier beforeMaturity() {
        require(
            block.timestamp < maturity,
            "Pool: Too late"
        );
        _;
    }

    /// @dev Overflow-protected addition, from OpenZeppelin
    function add(uint128 a, uint128 b)
        internal pure returns (uint128)
    {
        uint128 c = a + b;
        require(c >= a, "Pool: Dai reserves too high");

        return c;
    }

    /// @dev Overflow-protected substraction, from OpenZeppelin
    function sub(uint128 a, uint128 b) internal pure returns (uint128) {
        require(b <= a, "Pool: fyDai reserves too low");
        uint128 c = a - b;

        return c;
    }

    /// @dev Safe casting from uint256 to uint128
    function toUint128(uint256 x) internal pure returns(uint128) {
        require(
            x <= type(uint128).max,
            "Pool: Cast overflow"
        );
        return uint128(x);
    }

    /// @dev Safe casting from uint256 to int256
    function toInt256(uint256 x) internal pure returns(int256) {
        require(
            x <= uint256(type(int256).max),
            "Pool: Cast overflow"
        );
        return int256(x);
    }

    /// @dev Mint initial liquidity tokens.
    /// The liquidity provider needs to have called `dai.approve`
    /// @param daiIn The initial Dai liquidity to provide.
    function init(uint256 daiIn)
        internal
        beforeMaturity
        returns (uint256)
    {
        require(
            totalSupply() == 0,
            "Pool: Already initialized"
        );
        // no fyDai transferred, because initial fyDai deposit is entirely virtual
        dai.transferFrom(msg.sender, address(this), daiIn);
        _mint(msg.sender, daiIn);
        emit Liquidity(maturity, msg.sender, msg.sender, -toInt256(daiIn), 0, toInt256(daiIn));

        return daiIn;
    }

    /// @dev Mint liquidity tokens in exchange for adding dai and fyDai
    /// The liquidity provider needs to have called `dai.approve` and `fyDai.approve`.
    /// @param from Wallet providing the dai and fyDai. Must have approved the operator with `pool.addDelegate(operator)`.
    /// @param to Wallet receiving the minted liquidity tokens.
    /// @param daiOffered Amount of `dai` being invested, an appropriate amount of `fyDai` to be invested alongside will be calculated and taken by this function from the caller.
    /// @return The amount of liquidity tokens minted.
    function mint(address from, address to, uint256 daiOffered)
        external override
        onlyHolderOrDelegate(from, "Pool: Only Holder Or Delegate")
        returns (uint256)
    {
        uint256 supply = totalSupply();
        if (supply == 0) return init(daiOffered);

        uint256 daiReserves = dai.balanceOf(address(this));
        // use the actual reserves rather than the virtual reserves
        uint256 fyDaiReserves = fyDai.balanceOf(address(this));
        uint256 tokensMinted = supply.mul(daiOffered).div(daiReserves);
        uint256 fyDaiRequired = fyDaiReserves.mul(tokensMinted).div(supply);

        require(daiReserves.add(daiOffered) <= type(uint128).max); // fyDaiReserves can't go over type(uint128).max
        require(supply.add(fyDaiReserves.add(fyDaiRequired)) <= type(uint128).max); // fyDaiReserves can't go over type(uint128).max

        require(dai.transferFrom(from, address(this), daiOffered));
        require(fyDai.transferFrom(from, address(this), fyDaiRequired));
        _mint(to, tokensMinted);
        emit Liquidity(maturity, from, to, -toInt256(daiOffered), -toInt256(fyDaiRequired), toInt256(tokensMinted));

        return tokensMinted;
    }

    /// @dev Mint liquidity tokens in exchange for adding only dai
    /// The liquidity provider needs to have called `dai.approve`.
    /// @param from Wallet providing the dai and fyDai. Must have approved the operator with `pool.addDelegate(operator)`.
    /// @param to Wallet receiving the minted liquidity tokens.
    /// @param fyDaiToBuy Amount of `fyDai` being bought in the Pool, from this we calculate how much Dai it will be taken in.
    /// @return The amount of liquidity tokens minted.
    function buyFYDaiAndMint(address from, address to, uint256 fyDaiToBuy)
        external
        onlyHolderOrDelegate(from, "Pool: Only Holder Or Delegate")
        returns (uint256, uint256)
    {
        uint256 supply = totalSupply();
        require(supply > 0, "Pool: Use mint first");

        uint256 daiReserves = dai.balanceOf(address(this));
        uint256 fyDaiReserves = fyDai.balanceOf(address(this));

        uint256 daiIn = buyFYDaiPreview(toUint128(fyDaiToBuy)); // This is a virtual buy

        require(fyDaiReserves >= fyDaiToBuy, "Pool: Not enough fyDai"); // TODO: Isn't this checked in YieldMath?
        uint256 tokensMinted = supply.mul(fyDaiToBuy).div(fyDaiReserves.sub(fyDaiToBuy));
        daiIn = daiReserves.add(daiIn).mul(tokensMinted).div(supply);
        require(daiReserves.add(daiIn) <= type(uint128).max, "Pool: Too much Dai");

        require(dai.transferFrom(from, address(this), daiIn), "Pool: Dai transfer failed");
        _mint(to, tokensMinted);
        emit Liquidity(maturity, from, to, -toInt256(daiIn), 0, toInt256(tokensMinted));

        return (daiIn, tokensMinted);
    }

        /// @dev Mint liquidity tokens in exchange for adding only dai
    /// The liquidity provider needs to have called `dai.approve`.
    /// @param from Wallet providing the dai and fyDai. Must have approved the operator with `pool.addDelegate(operator)`.
    /// @param to Wallet receiving the minted liquidity tokens.
    /// @param daiToBuy Amount of `Dai` being bought in the Pool, from this we calculate how much fyDai it will be taken in.
    /// @return The amount of liquidity tokens minted.
    function buyDaiAndMint(address from, address to, uint256 daiToBuy)
        external
        onlyHolderOrDelegate(from, "Pool: Only Holder Or Delegate")
        returns (uint256, uint256)
    {
        uint256 supply = totalSupply();
        require(supply > 0, "Pool: Use mint first");

        uint256 daiReserves = dai.balanceOf(address(this));
        uint256 fyDaiReserves = fyDai.balanceOf(address(this));

        uint256 fyDaiIn = buyDaiPreview(toUint128(daiToBuy)); // This is a virtual buy

        uint256 tokensMinted = supply.mul(daiToBuy).div(daiReserves.sub(daiToBuy));
        fyDaiIn = fyDaiReserves.add(fyDaiIn).mul(tokensMinted).div(supply);

        require(fyDai.transferFrom(from, address(this), fyDaiIn), "Pool: FYDai transfer failed");
        _mint(to, tokensMinted);
        emit Liquidity(maturity, from, to, 0, -toInt256(fyDaiIn), toInt256(tokensMinted));

        return (fyDaiIn, tokensMinted);
    }

    /// @dev Burn liquidity tokens in exchange for dai and fyDai.
    /// The liquidity provider needs to have called `pool.approve`.
    /// @param from Wallet providing the liquidity tokens. Must have approved the operator with `pool.addDelegate(operator)`.
    /// @param to Wallet receiving the dai and fyDai.
    /// @param tokensBurned Amount of liquidity tokens being burned.
    /// @return The amount of reserve tokens returned (daiTokens, fyDaiTokens).
    function burn(address from, address to, uint256 tokensBurned)
        external override
        onlyHolderOrDelegate(from, "Pool: Only Holder Or Delegate")
        returns (uint256, uint256)
    {
        uint256 supply = totalSupply();
        uint256 daiReserves = dai.balanceOf(address(this));
        // use the actual reserves rather than the virtual reserves
        uint256 daiOut;
        uint256 fyDaiOut;
        { // avoiding stack too deep
            uint256 fyDaiReserves = fyDai.balanceOf(address(this));
            daiOut = tokensBurned.mul(daiReserves).div(supply);
            fyDaiOut = tokensBurned.mul(fyDaiReserves).div(supply);
        }

        _burn(from, tokensBurned); // TODO: Fix to check allowance
        dai.transfer(to, daiOut);
        fyDai.transfer(to, fyDaiOut);
        emit Liquidity(maturity, from, to, toInt256(daiOut), toInt256(fyDaiOut), -toInt256(tokensBurned));

        return (daiOut, fyDaiOut);
    }

    /// @dev Burn liquidity tokens in exchange for dai.
    /// The liquidity provider needs to have called `pool.approve`.
    /// @param from Wallet providing the liquidity tokens. Must have approved the operator with `pool.addDelegate(operator)`.
    /// @param to Wallet receiving the dai and fyDai.
    /// @param tokensBurned Amount of liquidity tokens being burned.
    /// @return The amount of dai tokens returned.
    function burnAndSellFYDai(address from, address to, uint256 tokensBurned)
        external
        onlyHolderOrDelegate(from, "Pool: Only Holder Or Delegate")
        returns (uint256)
    {
        uint256 supply = totalSupply();
        uint256 daiReserves = dai.balanceOf(address(this));
        // use the actual reserves rather than the virtual reserves
        uint256 daiOut;
        uint256 fyDaiObtained;
        { // avoiding stack too deep
            uint256 fyDaiReserves = fyDai.balanceOf(address(this));
            daiOut = tokensBurned.mul(daiReserves).div(supply);
            fyDaiObtained = tokensBurned.mul(fyDaiReserves).div(supply);
        }

        daiOut = daiOut.add(
            YieldMath.daiOutForFYDaiIn(                            // This is a virtual sell
                toUint128(daiReserves.sub(daiOut)),                // Real reserves, minus virtual burn
                sub(getFYDaiReserves(), toUint128(fyDaiObtained)), // Virtual reserves, minus virtual burn
                toUint128(fyDaiObtained),                          // Sell the virtual fyDai obtained
                toUint128(maturity - block.timestamp),             // This can't be called after maturity
                k,
                g2
            )
        );

        _burn(from, tokensBurned); // TODO: Fix to check allowance
        dai.transfer(to, daiOut);
        emit Liquidity(maturity, from, to, toInt256(daiOut), 0, -toInt256(tokensBurned));

        return daiOut;
    }

    /// @dev Burn liquidity tokens in exchange for fyDai.
    /// The liquidity provider needs to have called `pool.approve`.
    /// @param from Wallet providing the liquidity tokens. Must have approved the operator with `pool.addDelegate(operator)`.
    /// @param to Wallet receiving the dai and fyDai.
    /// @param tokensBurned Amount of liquidity tokens being burned.
    /// @return The amount of fyDai tokens returned.
    function burnAndSellDai(address from, address to, uint256 tokensBurned)
        external
        onlyHolderOrDelegate(from, "Pool: Only Holder Or Delegate")
        returns (uint256)
    {
        uint256 supply = totalSupply();
        uint256 daiReserves = dai.balanceOf(address(this));
        // use the actual reserves rather than the virtual reserves
        uint256 daiObtained;
        uint256 fyDaiOut;
        { // avoiding stack too deep
            uint256 fyDaiReserves = fyDai.balanceOf(address(this));
            daiObtained = tokensBurned.mul(daiReserves).div(supply);
            fyDaiOut = tokensBurned.mul(fyDaiReserves).div(supply);
        }

        fyDaiOut = fyDaiOut.add(
            YieldMath.fyDaiOutForDaiIn(                                     // This is a virtual sell
                toUint128(daiReserves),                                     // Real reserves, minus virtual burn
                sub(getFYDaiReserves(), toUint128(fyDaiOut)),               // Virtual reserves, minus virtual burn
                toUint128(daiObtained),                                     // Sell the virtual fyDai obtained
                toUint128(maturity - block.timestamp),                      // This can't be called after maturity
                k,
                g2
            )
        );

        _burn(from, tokensBurned); // TODO: Fix to check allowance
        fyDai.transfer(to, fyDaiOut);
        emit Liquidity(maturity, from, to, 0, toInt256(fyDaiOut), -toInt256(tokensBurned));

        return fyDaiOut;
    }

    /// @dev Sell Dai for fyDai
    /// The trader needs to have called `dai.approve`
    /// @param from Wallet providing the dai being sold. Must have approved the operator with `pool.addDelegate(operator)`.
    /// @param to Wallet receiving the fyDai being bought
    /// @param daiIn Amount of dai being sold that will be taken from the user's wallet
    /// @return Amount of fyDai that will be deposited on `to` wallet
    function sellDai(address from, address to, uint128 daiIn)
        external override
        onlyHolderOrDelegate(from, "Pool: Only Holder Or Delegate")
        returns(uint128)
    {
        uint128 fyDaiOut = sellDaiPreview(daiIn);

        dai.transferFrom(from, address(this), daiIn);
        fyDai.transfer(to, fyDaiOut);
        emit Trade(maturity, from, to, -toInt256(daiIn), toInt256(fyDaiOut));

        return fyDaiOut;
    }

    /// @dev Returns how much fyDai would be obtained by selling `daiIn` dai
    /// @param daiIn Amount of dai hypothetically sold.
    /// @return Amount of fyDai hypothetically bought.
    function sellDaiPreview(uint128 daiIn)
        public view override
        beforeMaturity
        returns(uint128)
    {
        uint128 daiReserves = getDaiReserves();
        uint128 fyDaiReserves = getFYDaiReserves();

        uint128 fyDaiOut = YieldMath.fyDaiOutForDaiIn(
            daiReserves,
            fyDaiReserves,
            daiIn,
            toUint128(maturity - block.timestamp), // This can't be called after maturity
            k,
            g1
        );

        require(
            sub(fyDaiReserves, fyDaiOut) >= add(daiReserves, daiIn),
            "Pool: fyDai reserves too low"
        );

        return fyDaiOut;
    }

    /// @dev Buy Dai for fyDai
    /// The trader needs to have called `fyDai.approve`
    /// @param from Wallet providing the fyDai being sold. Must have approved the operator with `pool.addDelegate(operator)`.
    /// @param to Wallet receiving the dai being bought
    /// @param daiOut Amount of dai being bought that will be deposited in `to` wallet
    /// @return Amount of fyDai that will be taken from `from` wallet
    function buyDai(address from, address to, uint128 daiOut)
        external override
        onlyHolderOrDelegate(from, "Pool: Only Holder Or Delegate")
        returns(uint128)
    {
        uint128 fyDaiIn = buyDaiPreview(daiOut);

        fyDai.transferFrom(from, address(this), fyDaiIn);
        dai.transfer(to, daiOut);
        emit Trade(maturity, from, to, toInt256(daiOut), -toInt256(fyDaiIn));

        return fyDaiIn;
    }

    /// @dev Returns how much fyDai would be required to buy `daiOut` dai.
    /// @param daiOut Amount of dai hypothetically desired.
    /// @return Amount of fyDai hypothetically required.
    function buyDaiPreview(uint128 daiOut)
        public view override
        beforeMaturity
        returns(uint128)
    {
        return YieldMath.fyDaiInForDaiOut(
            getDaiReserves(),
            getFYDaiReserves(),
            daiOut,
            toUint128(maturity - block.timestamp), // This can't be called after maturity
            k,
            g2
        );
    }

    /// @dev Sell fyDai for Dai
    /// The trader needs to have called `fyDai.approve`
    /// @param from Wallet providing the fyDai being sold. Must have approved the operator with `pool.addDelegate(operator)`.
    /// @param to Wallet receiving the dai being bought
    /// @param fyDaiIn Amount of fyDai being sold that will be taken from the user's wallet
    /// @return Amount of dai that will be deposited on `to` wallet
    function sellFYDai(address from, address to, uint128 fyDaiIn)
        external override
        onlyHolderOrDelegate(from, "Pool: Only Holder Or Delegate")
        returns(uint128)
    {
        uint128 daiOut = sellFYDaiPreview(fyDaiIn);

        fyDai.transferFrom(from, address(this), fyDaiIn);
        dai.transfer(to, daiOut);
        emit Trade(maturity, from, to, toInt256(daiOut), -toInt256(fyDaiIn));

        return daiOut;
    }

    /// @dev Returns how much dai would be obtained by selling `fyDaiIn` fyDai.
    /// @param fyDaiIn Amount of fyDai hypothetically sold.
    /// @return Amount of Dai hypothetically bought.
    function sellFYDaiPreview(uint128 fyDaiIn)
        public view override
        beforeMaturity
        returns(uint128)
    {
        return YieldMath.daiOutForFYDaiIn(
            getDaiReserves(),
            getFYDaiReserves(),
            fyDaiIn,
            toUint128(maturity - block.timestamp), // This can't be called after maturity
            k,
            g2
        );
    }

    /// @dev Buy fyDai for dai
    /// The trader needs to have called `dai.approve`
    /// @param from Wallet providing the dai being sold. Must have approved the operator with `pool.addDelegate(operator)`.
    /// @param to Wallet receiving the fyDai being bought
    /// @param fyDaiOut Amount of fyDai being bought that will be deposited in `to` wallet
    /// @return Amount of dai that will be taken from `from` wallet
    function buyFYDai(address from, address to, uint128 fyDaiOut)
        external override
        onlyHolderOrDelegate(from, "Pool: Only Holder Or Delegate")
        returns(uint128)
    {
        uint128 daiIn = buyFYDaiPreview(fyDaiOut);

        dai.transferFrom(from, address(this), daiIn);
        fyDai.transfer(to, fyDaiOut);
        emit Trade(maturity, from, to, -toInt256(daiIn), toInt256(fyDaiOut));

        return daiIn;
    }


    /// @dev Returns how much dai would be required to buy `fyDaiOut` fyDai.
    /// @param fyDaiOut Amount of fyDai hypothetically desired.
    /// @return Amount of Dai hypothetically required.
    function buyFYDaiPreview(uint128 fyDaiOut)
        public view override
        beforeMaturity
        returns(uint128)
    {
        uint128 daiReserves = getDaiReserves();
        uint128 fyDaiReserves = getFYDaiReserves();

        uint128 daiIn = YieldMath.daiInForFYDaiOut(
            daiReserves,
            fyDaiReserves,
            fyDaiOut,
            toUint128(maturity - block.timestamp), // This can't be called after maturity
            k,
            g1
        );

        require(
            sub(fyDaiReserves, fyDaiOut) >= add(daiReserves, daiIn),
            "Pool: fyDai reserves too low"
        );

        return daiIn;
    }

    /// @dev Returns the "virtual" fyDai reserves
    function getFYDaiReserves()
        public view override
        returns(uint128)
    {
        return toUint128(fyDai.balanceOf(address(this)).add(totalSupply()));
    }

    /// @dev Returns the Dai reserves
    function getDaiReserves()
        public view override
        returns(uint128)
    {
        return toUint128(dai.balanceOf(address(this)));
    }
}
