pragma solidity >= 0.5.0 < 0.6.0;

/// Arpa Corp GAMES Dice Roller
/// @title A Roll Dicer Game paying Ethers
/// @author Carlos Mayorga Aguirre https://github.com/cmayorga
///
/// Revised by www.buclelabs.com

//                 ,###########      ,####################*,.   /#################(,,.        (##########*       
//                ,############(     ,#########################((#######################(,   (###########(,      
//               ,###############    ,#######(,.....*//#################,       .(########*.(##############*     
//              ,#######,.(#######.  ,#######*         #################.        ,################# ,#######*  
//             /#######*  .(#######. ,########(((((((########(,./##############(##################   /#######* 
//            /#######*    *#######(.,########################/./##################((//,*(######(    .(######(,
//           ################################*.     .,##################,              *#######################*
//         .#################################*        .#################,             *########################(,
//         ########/          /##############*         #################,            *#######(.         ,(#######*
//
//               ,@########&/           ##(,/      *,(###       .///(##/**,. (############(**,.  (########/  
//           ,*(#(,.      ./#(*.       ##&#/        .(###/      ./**###,  .,/(##             .,(##,      ,*(.
//         ,//##/                    ,##(.##/        /#(##,     .//#((#,    ,(##               /##/           
//        ,/*(##                    ,##(  .##*       /## (#,    ./##**#,    *(##               /###          
//        */.(#                     (#(    .##*      /## *##    .##(*(#////*.(##////((((/**///*, .(####/*    
//        ,/,(#      ./////(##.    (##,     .##*     /## ,/#(. .##/  *#*     (##                       //##(.
//         */###           *##.   (##//.     ,##,    /##,// #(.##(*  *#(/*   (##                          .##
//          ,/###          *##/, *(#  ,/*.    *#(.   /##/,  ,###(/*  *#, ,/* (##              ,.          .##
//             .*(##(*,,,,*(##/. .(#     .**/*,*(#/ /(##     //*./*  *#,    ,/###///////////   ,(###,..,..,##(,



import "github.com/provable-things/ethereum-api/provableAPI.sol";
import "https://github.com/OpenZeppelin/solidity-jwt/blob/master/contracts/Strings.sol";

contract DSSafeAddSub {
    function safeToAdd(uint a, uint b) internal pure returns (bool) {
        return (a + b >= a);
    }
    function safeAdd(uint a, uint b) internal pure returns (uint) {
        if (!safeToAdd(a, b)) revert();
        return a + b;
    }

    function safeToSubtract(uint a, uint b) internal pure returns (bool) {
        return (b <= a);
    }

    function safeSub(uint a, uint b) internal pure returns (uint) {
        if (!safeToSubtract(a, b)) revert();
        return a - b;
    } 
}

contract ERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function approveAndCall(address spender, uint tokens, bytes memory data) public returns (bool success);
}

contract ApproveAndCallFallBack {
    function receiveApproval(address _from, uint256 _amount, address _token, bytes memory _data) public;
}

contract ArpaGamesDiceRoller is usingProvable, DSSafeAddSub {
    
    using StringUtils for *;
        
    // Checks player profit, bet size and player number is within allowed range
    modifier betIsValid(uint _betSize, uint _playerNumber) {      
        if(((((_betSize * (100-(safeSub(_playerNumber,1)))) / (safeSub(_playerNumber,1))+_betSize))*houseEdge/houseEdgeDivisor)-_betSize > maxProfit || _betSize < minBet || _playerNumber < minNumber || _playerNumber > maxNumber) 
        revert('Bet conditions amounts do not fit game conditions');
		_;
    }

    modifier gameIsActive {
        require(gamePaused != true, 'Game paused, not available');
		_;
    }    

    // Checks if payouts are currently active
    modifier payoutsAreActive {
        require(payoutsPaused != true, 'Payouts paused,game not available');
		_;
    }    

    modifier onlyOwner {
         require(msg.sender == owner);
         _;
    }
    
    //Variables to control the Game
    uint constant public maxProfitDivisor = 1000000;
    uint constant public houseEdgeDivisor = 1000;    
    uint constant public maxNumber = 95; 
    uint constant public minNumber = 2;
	bool public gamePaused;
    address payable public owner;
    bool public payoutsPaused; 
    uint public contractBalance;
    uint public houseEdge;     
    uint public maxProfit;   
    uint public maxProfitAsPercentOfHouse;                    
    uint public minBet; 
    uint public maxPendingPayouts;
    uint public affiliateTokenSendToWinner = 100;
    address private affiliateTokenAddress = address(0x58c2A89Ff9522cF7f44C3B7b3C3DE2165eea9b5E);

    //Log explained texts - For debug purposes
    string private BET_SENT_FOR_NUMBER = "BetSentWaitingRND";
    string private PROVABLE_CALLBACK_CALLED = "ProvableCBcalled";
    string private BET_REFUND_NO_PROOF = "NoProvableProof,rfnd bet";
    string private BET_REFUND_FAILED = "BetRefundfailed";
    string private BET_REFUND_FROM_OWNER = "Bet rfnd < owner";
    string private BET_WON = "Win snd pfit+tkn 2 winner";
    string private BET_WON_SEND_FAILED = "WinSndPfitFailed";
    string private BET_LOST = "Lost no more Tx";

    //Player Variables
    mapping (bytes32 => address payable) playerAddress;
    mapping (bytes32 => address payable) playerTempAddress;
    mapping (bytes32 => bytes32) playerBetId;
    mapping (bytes32 => uint) playerBetValue;
    mapping (bytes32 => uint) playerTempBetValue;               
    mapping (bytes32 => uint) playerDieResult;
    mapping (bytes32 => uint) playerNumber;
    mapping (address => uint) playerPendingWithdrawals;
    mapping (bytes32 => uint) playerProfit;
    mapping (bytes32 => uint) playerTempReward;           

    //Variables for probable Random Number from third party provider - Provable.xyz
    uint256 constant MAX_INT_FROM_BYTE = 256;
    uint256 constant NUM_RANDOM_BYTES_REQUESTED = 7;
    uint256 constant QUERY_EXECUTION_DELAY = 0;
    uint256 constant GAS_FOR_PROVABLE_CALLBACK = 400000;
    mapping (bytes32 => bool) public queries;
    
    //Web3 Game Events
    event LogBet(bytes32 indexed BetID, address indexed PlayerAddress, uint indexed RewardValue, uint ProfitValue, uint BetValue, uint PlayerNumber, bytes32 provable_qryId, string result_details);      
        // Output to web3 UI on bet result - Status: 0=lose, 1=win, 2=win + failed send, 3=refund, 4=refund + failed send
	event LogResult(uint indexed ResultSerialNumber, bytes32 indexed BetID, address indexed PlayerAddress, uint PlayerNumber, uint DiceResult, uint Value, int Status, bytes Proof, string result_details);   
    event LogRefund(bytes32 indexed BetID, address indexed PlayerAddress, uint indexed RefundValue, string result_details);
    event LogOwnerTransfer(address indexed SentToAddress, uint indexed AmountTransferred);
    
    //Debug events
    event LogDebug(string texto);
    event LogNewProvableQuery(string description);
    event generatedRandomNumber(uint256 randomNumber);    

    // --- Manage Affiliate Tokens
    ERC20 public ERC20Interface;  
  
    //Events to manage Fidelity tokens transfer  
    event TransferSuccessful(address indexed from_, address indexed to_, uint256 amount_);
    event TransferFailed(address indexed from_, address indexed to_, uint256 amount_);  
  
    // Owner can set Fidelity Token
    function setFidelityToken(address tokenaddress) public onlyOwner returns (bool) {  
        affiliateTokenAddress = tokenaddress;
        ERC20Interface = ERC20(affiliateTokenAddress);
        return true;  
    }
    
    function transferTokens(address to_, uint256 amount_) internal payoutsAreActive gameIsActive{  
        require(affiliateTokenAddress != address(0x0));
        require(amount_ > 0);  
        if (!ERC20Interface.transfer(to_, amount_*100000000)){
            emit LogDebug("There are not enough fidelity tokens to transfer");
        }
    }  
    // --- end Manage Affiliate Tokens  
    
    // Allow contract to receive funds 
    function() external payable {}  
  
    constructor() payable public {

        owner = msg.sender;
        provable_setProof(proofType_Ledger);
        
        // init 990 = 99% (1% houseEdge)
        ownerSetHouseEdge(990);
        // init 10,000 = 1% 
        ownerSetMaxProfitAsPercentOfHouse(500000);
        // init min bet (0.2 ether default)
        ownerSetMinBet(200000000000000000);
        ERC20Interface = ERC20(affiliateTokenAddress);        
    }

    // The main public function to roll the dices and get into the action!
    function playerRollDice(uint rollUnder) public payable gameIsActive betIsValid(msg.value, rollUnder)
	{
        bytes32 provable_qryId = provable_newRandomDSQuery(
            QUERY_EXECUTION_DELAY,
            NUM_RANDOM_BYTES_REQUESTED,
            GAS_FOR_PROVABLE_CALLBACK
        );
        queries[provable_qryId] = true;

		playerBetId[provable_qryId] = provable_qryId;
		playerNumber[provable_qryId] = rollUnder;
        playerBetValue[provable_qryId] = msg.value;
        playerAddress[provable_qryId] = msg.sender;
        playerProfit[provable_qryId] = ((((msg.value * (100-(safeSub(rollUnder,1)))) / (safeSub(rollUnder,1))+msg.value))*houseEdge/houseEdgeDivisor)-msg.value;        
        
        maxPendingPayouts = safeAdd(maxPendingPayouts, playerProfit[provable_qryId]);
        
        if(maxPendingPayouts >= contractBalance) revert();
        emit LogBet(playerBetId[provable_qryId], playerAddress[provable_qryId], safeAdd(playerBetValue[provable_qryId], playerProfit[provable_qryId]), playerProfit[provable_qryId], playerBetValue[provable_qryId], playerNumber[provable_qryId], provable_qryId, BET_SENT_FOR_NUMBER);          
    }

    //Provable Proof Callback
	function __callback(bytes32 _queryId, string memory _result, bytes memory _proof) public{
        require(msg.sender == provable_cbAddress(), 'Caller is not the Provable address!');
        require(queries[_queryId], 'QueryID is not an expected one!');
        if (
            provable_randomDS_proofVerify__returnCode(
                _queryId,
                _result,
                _proof
            ) != 0
        ) {
            /**
            * @notice  The proof verification has failed! 
            */
            playerDieResult[_queryId] = 0;
            playerTempAddress[_queryId] = playerAddress[_queryId]; delete playerAddress[_queryId];
            playerTempReward[_queryId] = playerProfit[_queryId]; playerProfit[_queryId] = 0; 
            // Reduce maxPendingPayouts liability
            maxPendingPayouts = safeSub(maxPendingPayouts, playerTempReward[_queryId]);         
            playerTempBetValue[_queryId] = playerBetValue[_queryId]; playerBetValue[_queryId] = 0; 
            /*
            * refund
            * if result is 0 result is empty or no proof refund original bet value
            * if refund fails save refund value to playerPendingWithdrawals
            */
            emit LogResult(0, playerBetId[_queryId], playerTempAddress[_queryId], playerNumber[_queryId], playerDieResult[_queryId], playerTempBetValue[_queryId], 3, _proof, BET_REFUND_NO_PROOF);            
            /*
            * send refund - external call to an untrusted contract
            * if send fails map refund value to playerPendingWithdrawals[address]
            * for withdrawal later via playerWithdrawPendingTransactions
            */
            (bool success,) = playerTempAddress[_queryId].call.value(playerTempBetValue[_queryId])("");
            if(!success){
                emit LogResult(0, playerBetId[_queryId], playerTempAddress[_queryId], playerNumber[_queryId], playerDieResult[_queryId], playerTempBetValue[_queryId], 4, _proof, BET_REFUND_FAILED);              
                /* if send failed let player withdraw via playerWithdrawPendingTransactions */
                playerPendingWithdrawals[playerTempAddress[_queryId]] = safeAdd(playerPendingWithdrawals[playerTempAddress[_queryId]], playerTempBetValue[_queryId]);                        
                setMaxProfit();
                //Fidelity tokens not applicable for refund
            }
            return;
        } else {
            uint256 ceiling = (MAX_INT_FROM_BYTE ** NUM_RANDOM_BYTES_REQUESTED) - 1;
            uint256 randomNumber = uint256(keccak256(abi.encodePacked(_result))) % ceiling;
            uint randomNumberInRange = (randomNumber % 100) + 1;            
            reconciliateCallBackBet(_queryId, randomNumberInRange, _proof);
        }
	}
    
	function reconciliateCallBackBet(bytes32 myid, uint resultNumber, bytes memory proof) internal payoutsAreActive 
	{  
	    require(msg.sender == provable_cbAddress(), 'Caller is not the Provable address!');	    
        require(playerAddress[myid]!=address(0x0));
        
        playerDieResult[myid] = resultNumber;
        playerTempAddress[myid] = playerAddress[myid]; 
        delete playerAddress[myid];
        playerTempReward[myid] = playerProfit[myid]; 
        playerProfit[myid] = 0; 
        // Reduce maxPendingPayouts liability
        maxPendingPayouts = safeSub(maxPendingPayouts, playerTempReward[myid]);         
        playerTempBetValue[myid] = playerBetValue[myid]; playerBetValue[myid] = 0; 
        
        /*
        * pay winner
        * update contract balance to calculate new max bet
        * send reward
        * if send of reward fails save value to playerPendingWithdrawals        
        */        
        if(playerDieResult[myid] < playerNumber[myid]){ 

            /* safely reduce contract balance by player profit */
            contractBalance = safeSub(contractBalance, playerTempReward[myid]); 

            /* safely calculate payout via profit plus original wager */
            playerTempReward[myid] = safeAdd(playerTempReward[myid], playerTempBetValue[myid]); 

            emit LogResult(0, playerBetId[myid], playerTempAddress[myid], playerNumber[myid], playerDieResult[myid], playerTempReward[myid], 1, proof, BET_WON);                            

            /* update maximum profit */
            setMaxProfit();
            
            /*
            * send win - external call to an untrusted contract
            * if send fails map reward value to playerPendingWithdrawals[address]
            * for withdrawal later via playerWithdrawPendingTransactions
            */
            (bool success,) = playerTempAddress[myid].call.value(playerTempReward[myid])("");
            if(!success){
                emit LogResult(0, playerBetId[myid], playerTempAddress[myid], playerNumber[myid], playerDieResult[myid], playerTempReward[myid], 2, proof, BET_WON_SEND_FAILED);                   
                /* if send failed let player withdraw via playerWithdrawPendingTransactions */
                playerPendingWithdrawals[playerTempAddress[myid]] = safeAdd(playerPendingWithdrawals[playerTempAddress[myid]], playerTempReward[myid]);                               
            }
            transferTokens(playerTempAddress[myid], 100);
            return;

        }
        /*
        * no win
        * send 1 wei to a losing bet
        * update contract balance to calculate new max bet
        */
        if(playerDieResult[myid] >= playerNumber[myid]){
            emit LogResult(0, playerBetId[myid], playerTempAddress[myid], playerNumber[myid], playerDieResult[myid], playerTempBetValue[myid], 0, proof, BET_LOST);                                
            /*  
            *  safe adjust contractBalance
            *  setMaxProfit
            *  send 1 wei to losing bet
            */
            contractBalance = safeAdd(contractBalance, (playerTempBetValue[myid]-1));
            /* update maximum profit */
            setMaxProfit(); 
            /*
            * send 1 wei - external call to an untrusted contract                  
            */
            (bool success,) = playerTempAddress[myid].call.value(1)("");
            if(!success){
                /* if send failed let player withdraw via playerWithdrawPendingTransactions */                
               playerPendingWithdrawals[playerTempAddress[myid]] = safeAdd(playerPendingWithdrawals[playerTempAddress[myid]], 1);                                
            }                                   
            return;
        }
    }  
    
    
    // Allow a player to withdraw his pendants payouts
    function playerWithdrawPendingTransactions() public payoutsAreActive returns (bool)
     {
        uint withdrawAmount = playerPendingWithdrawals[msg.sender];
        playerPendingWithdrawals[msg.sender] = 0;
        /* external call to untrusted contract */        
        (bool success,) = msg.sender.call.value(withdrawAmount)("");
        if(!success){
            /* if send failed revert playerPendingWithdrawals[msg.sender] = 0; */
            /* player can try to withdraw again later */
            playerPendingWithdrawals[msg.sender] = withdrawAmount;
            return false;
        }

    }

    // check for pending withdrawals
    function playerGetPendingTxByAddress(address addressToCheck) public view returns (uint) {
        return playerPendingWithdrawals[addressToCheck];
    }
    
    // internal function to set max profit calculated by balance available and pending payouts
    function setMaxProfit() internal {
        maxProfit = (contractBalance*maxProfitAsPercentOfHouse)/maxProfitDivisor;  
    }      


    // set gas price for provable callback
    function ownerSetCallbackGasPrice(uint newCallbackGasPrice) public onlyOwner
	{
        provable_setCustomGasPrice(newCallbackGasPrice);
    }     


    // only owner adjust contract balance variable (only used for max profit calc)
    function ownerUpdateContractBalance(uint newContractBalanceInWei) public onlyOwner
    {        
       contractBalance = newContractBalanceInWei;
       setMaxProfit();
    }    

    // only owner address can set houseEdge
    function ownerSetHouseEdge(uint newHouseEdge) public onlyOwner
    {
        houseEdge = newHouseEdge;
    }

    // only owner address can set maxProfitAsPercentOfHouse
    function ownerSetMaxProfitAsPercentOfHouse(uint newMaxProfitAsPercent) public onlyOwner
    {
        maxProfitAsPercentOfHouse = newMaxProfitAsPercent;
        setMaxProfit();
    }

    // only owner address can set minBet
    function ownerSetMinBet(uint newMinimumBet) public onlyOwner
    {
        minBet = newMinimumBet;
    }       

    // only owner address can transfer ether
    function ownerTransferEther(address payable sendTo, uint amount) public onlyOwner
    {        
        /* safely update contract balance when sending out funds*/
        contractBalance = safeSub(contractBalance, amount);		
        /* update max profit */
        setMaxProfit();
        sendTo.transfer(amount);
        emit LogOwnerTransfer(sendTo, amount); 
    }

    // only owner address can set emergency pause #1
    function ownerPauseGame(bool newStatus) public onlyOwner
    {
		gamePaused = newStatus;
    }

    // only owner address can set emergency pause #2
    function ownerPausePayouts(bool newPayoutStatus) public onlyOwner
    {
		payoutsPaused = newPayoutStatus;
    } 


    // only owner address can set owner address
    function ownerChangeOwner(address payable newOwner) public onlyOwner
	{
        owner = newOwner;
    }

    // only owner address can suicide - emergency
    function ownerkill() public onlyOwner
	{
		selfdestruct(msg.sender);
	}    
}
