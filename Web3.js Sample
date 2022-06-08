/*
A sample Web3.js script used to interact with and write to the Vesting
Smart Contract by updating the mapping. Allotment data is pulled from a .csv file.
*/

const Web3 = require('Web3');
const Contract = require('./build/contracts/Contract.json');
const infuraURL = 'https://mainnet.infura.io/v3/**KEY**';
const private_key = "**PRIVATE KEY**";
const ContractAddress = '**CONTRACT ADDRESS**';

const init = async () => {
    const web3 = new Web3(infuraURL);
    const networkId = await web3.eth.net.getId();
    const deployedNetwork = PyeClaim.networks[networkId];
    const contract = new web3.eth.Contract(
        Contract.abi,
        deployedNetwork.address
    );

    const contractOwner = await contract.methods.owner().call();
    const tx = contract.methods.setAllotment("**SOME ADDRESS**", BigInt(**TOKEN BALANCE**));
    const gas = await tx.estimateGas({from: contractOwner});
    const gasPrice = await web3.eth.getGasPrice();
    const data = tx.encodeABI();
    const nonce = await web3.eth.getTransactionCount(contractOwner);

    const signedTx = await web3.eth.accounts.signTransaction(
        {
            to: ContractAddress,
            data,
            gas,
            gasPrice,
            nonce,
            chainId: networkId
        },
        private_key
       );

    const receipt = await web3.eth.sendSignedTransaction(signedTx.rawTransaction);
    const allotment = await contract.methods.getPYEAllotment("**SOME ADDRESS**").call();
    console.log(`Transaction hash: ${receipt.transactionHash}`, `New Allotment: ${allotment}`);
}

init();
