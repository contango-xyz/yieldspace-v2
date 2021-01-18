
const func = async function ({ deployments, getNamedAccounts, getChainId }) {
  const { deploy, get, read, execute } = deployments;
  const { deployer } = await getNamedAccounts();
  const chainId = await getChainId()

  const daiMock = await deploy('DaiMock', {
    from: deployer,
    deterministicDeployment: true,
    args: []
  })

  console.log(`Deployed DaiMock to ${daiMock.address}`);
}

module.exports = func;
module.exports.tags = ["DaiMock"];