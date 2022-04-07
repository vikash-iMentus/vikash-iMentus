//  SPDX-License-Identifier: MIT
import "./lib/SafeMath.sol";
import "hardhat/console.sol";
pragma solidity >=0.6.0 <0.8.0;

contract Staking {
    using SafeMath for uint256;

  
  enum Status {
        // validator not exist, default status
        NotExist,
        // validator created
        Created,
        // anyone has staked for the validator
        Staked,
        // validator's staked coins < MinimalStakingCoin
        Unstaked,
        // validator is jailed by system(validator have to repropose)
        Jailed
    }

    // Validator Struct
    struct Validator {
        address validator;
        Status status;
        uint256 amount; // self amount
        uint256 coins; //  self + delegators
        uint256 income; // self income
        uint256 TotalIncome; // total income
        address[] delegators;
    }

    //Delegator Struct
    struct Delegator {
        address delegatorAddress; //  delegator self address
        uint256 amount; // self stake
        uint256 unstakeblock; // unstakeblock = 0 means can stake if !=0 already unstake
        uint256 index; // index no represent in stakers array in Validator Struct
        uint256 income; // delegator income
    }

    // Validator Address  = > Get Validator Information
    mapping(address => Validator) validatorInfo;
    // Delegator Address => Validator Address =>Staking Info
    mapping(address => mapping(address => Delegator)) stakingInfo;

    address[] public currentValidators; // All Validators
    address[] public highestValidators; // Only Top 21

    uint256 public totalDXTStake; //  To DXT Stake Amount


    /**********Punish Params**********/

    uint256 public  constant removeThreshold = 48; // distribute revenue & kick out from validator set
    uint256 public constant punishThreshold = 24; // only distribute to better validators

    struct PunishRecord {
        uint256 missedBlockCounter;
        uint256 index;
        bool isPunished;
    }

    mapping(address => PunishRecord) punishRecord;
    //Mapping for Block Number Tracking
    // mapping(uint256 => bool) punished;
    // mapping(uint256 => bool) decreased;

    address[] public punishValidator;

    /**********Constant**********/
    uint256 public constant minimumStakeAmount = 10 ether; // Minimum Stake DXT
    uint256 public constant MaxValidators = 3; // Total Max Validator
    uint64 public constant StakingLockPeriod = 10 seconds; // Stake Locking Period

        /***************state of the contract******************/
    // uint256 public minimumStakeAmount;
    // uint256 public MaxValidators;


    /**********Events**********/
    event StakeValidator(
        address indexed validator,
        uint256 amount,
        uint256 time
    );
    event StakeDelegator(
        address indexed delegator,
        address indexed validator,
        uint256 amount,
        uint256 time
    );
    event RemoveFromHighestValidators(
        address indexed validator,
        uint256 time
    );
    event RemoveFromCurrentValidatorsList(
        address indexed validator,
        uint256 time
    );
    event UnstakeValidator(
        address indexed validator,
        uint256 indexed amount,
        uint256 time
    );
    event UnstakeDelegator(
        address indexed validator,
        address indexed delegator,
        uint256 amount,
        uint256 time
    );
    event WithdrawValidatorStaking(
        address indexed validator,
        uint256 indexed amount,
        uint256 time
    );
    event WithdrawDelegatorStaking(
        address indexed delegator,
        address indexed validator,
        uint256 indexed amount,
        uint256 time
    );
    event DelegatorClaimReward(
        address indexed delegator,
        address indexed validator,
        uint256 amount,
        uint256 time
    );
    event ValidatorClaimReward(
        address indexed validator,
        uint256 amount,
        uint256 time
    );
    event PunishValidator(
        address indexed validator,
        uint256 time
    );

    /**********Modifiers**********/
    modifier zeroAddress{
        _zeroAddress();
        _;
    }

    function stakeValidator() external payable  returns (bool) {
        address staker = msg.sender; // validator address
        uint256 stakeamount = msg.value; // 

        //Struct Validator Variable
        Validator storage valInfo = validatorInfo[staker];
        Delegator storage stakeInfo = stakingInfo[staker][staker];
        if (stakeamount < 0) {
            return false;
        }
        // Check for Minimum Stake DXT
        require(stakeamount >= minimumStakeAmount, "Must Stake 10 or More");
        // Check for the Validator Jail
        require( valInfo.status!= Status.Jailed, "Validator Jailed");
        if (valInfo.amount == 0 && Status.NotExist == valInfo.status) {
            valInfo.validator = staker;
            valInfo.status = Status.Created;
            valInfo.amount = valInfo.amount.add(stakeamount);
            valInfo.coins = valInfo.coins.add(stakeamount);
        } else if (valInfo.amount > 0 && (Status.Staked == valInfo.status || Status.Unstaked == valInfo.status)
        ) {

            valInfo.amount = valInfo.amount.add(stakeamount);
            valInfo.coins = valInfo.coins.add(stakeamount);

            // Update The Block No
            stakeInfo.unstakeblock = 0;

        }

        if (highestValidators.length < MaxValidators && !isTopValidator(staker)){
            highestValidators.push(staker); // push into highestValidator if there is space
        } else if (highestValidators.length >= MaxValidators && !isTopValidator(staker)) {
            
            // Find The Lowest Coins Address & Index in HighestValidators List
            uint256 lowCoin;
            uint256 lowIdx;
            address lowAddress;
            
            (lowCoin,lowIdx,lowAddress) = lowestCoinsInHighestValidator();

        
            if (valInfo.coins > lowCoin) {
                highestValidators[lowIdx] = staker;
            }
        }

        // Change the Status to Staked
        if (valInfo.status != Status.Staked) {
            valInfo.status = Status.Staked;
        }
        if (!isActiveValidator(staker)) {
            currentValidators.push(staker);
        }

        totalDXTStake = totalDXTStake.add(stakeamount);
      
        //  testIncome(staker);
         
        uint256 highCoin;
        uint256 highIdx;
        address addValAddress;

        (highCoin,highIdx,addValAddress)= highestCoinsInCurrentValidatorsNotInTopValidator();

        //console.log("validator to be add", addValAddress);

        if(highestValidators.length < MaxValidators && addValAddress!=address(0)){
            highestValidators.push(addValAddress);
        }
        emit StakeValidator(staker, stakeamount, block.timestamp);
        return true;
    }

    function stakeDelegator(address validator) external payable  returns (bool) {
        address staker = msg.sender; //Delegator Address
        uint256 stakeamount = msg.value; // Stake Amount

        if (stakeamount < 0) {
            return false;
        }
        // Struct Validator
        Validator storage valInfo = validatorInfo[validator];
        // Struct Delegator
        Delegator storage stakeInfo = stakingInfo[staker][validator];
        require(Status.Jailed != valInfo.status, "Validator Jailed");
        require(isActiveValidator(validator),"Validator Not Exist");
       
         if (valInfo.status == Status.Staked) {
            // Update Validator Coins
            valInfo.coins = valInfo.coins.add(stakeamount); // update in Validator Amount (Self)
            stakeInfo.amount = stakeInfo.amount.add(stakeamount); // update in Validator Coins(Total)

            stakeInfo.delegatorAddress = staker; // update in Delegator Staking Struct 
            stakeInfo.index = valInfo.delegators.length; // update the index of delegator struct for  delegators array in validator
            if(valInfo.delegators.length == 0){
                valInfo.delegators.push(staker);
            } else if(!isDelegatorsExist(staker,valInfo.delegators)){
                valInfo.delegators.push(staker);
             }
            
        }

        if (highestValidators.length < MaxValidators && !isTopValidator(validator)){
            highestValidators.push(validator); // push into highestValidator if there is space
        } else if (highestValidators.length >= MaxValidators && !isTopValidator(validator)) {

            // Find The Lowest Coins Address & Index in HighestValidators List
            uint256 lowCoin;
            uint256 lowIdx;
            address lowAddress;
            
            (lowCoin,lowIdx,lowAddress) = lowestCoinsInHighestValidator();

            if (
                valInfo.coins > lowCoin
            ) {
                if (!isTopValidator(validator)) {
                    highestValidators[lowIdx] = validator;
                }
            }
        }

        // Change the Status to Staked
        if (valInfo.status != Status.Staked) {
            valInfo.status = Status.Staked;
        }
        totalDXTStake = totalDXTStake.add(stakeamount);

        emit StakeDelegator(staker, validator, stakeamount, block.timestamp);
        return true;
    }

    function unstakeValidator() external  returns (bool) {
        address staker = msg.sender; //get the validator address
        //Struct Validator
        Validator storage valInfo = validatorInfo[staker];
        Delegator storage stakeInfo = stakingInfo[staker][staker];

        uint256 unstakeamount = valInfo.amount; // self amount validator

        // Check for the unstakeBlock status
        require(stakingInfo[staker][staker].unstakeblock == 0,"Already in Unstaking Status");
        require(unstakeamount > 0, "Don't have any stake");
        require(highestValidators.length != 1 && isActiveValidator(staker),
            "Can't Unstake, Validator List Empty "
        );


        // Set Block No When Validator Unstake
        stakeInfo.unstakeblock = block.number;

        // Remove From The Highest 
        removeFromHighestValidatorList(staker);
        valInfo.status = Status.Unstaked;
         // Get Highest Validator From Current List 
        uint256 highCoin;
        uint256 highIdx;
        address addValAddress;

        (highCoin,highIdx,addValAddress)= highestCoinsInCurrentValidatorsNotInTopValidator();

        //console.log("validator to be add", addValAddress);

        if(highestValidators.length < MaxValidators && addValAddress!=address(0)){
            highestValidators.push(addValAddress);
        }

        emit UnstakeValidator(staker, unstakeamount, block.timestamp);
        return true;
    }

    function unstakeDelegators(address validator) external  returns (bool) {
        address delegator = msg.sender; //get Delegator Address
        // Struct Delegator
        Delegator storage stakeInfo = stakingInfo[delegator][validator];
        Validator storage valInfo = validatorInfo[validator]; // Struct Validator

        require(stakeInfo.unstakeblock == 0, "Already in unstaking status");
        require(Status.Jailed != valInfo.status, "Validator Jailed");
        uint256 unstakeamount = stakeInfo.amount; // get the staking info
        require(unstakeamount > 0, "don't have any stake");
        require(
            highestValidators.length != 1,
            "You can't unstake, validator list will be empty after this operation!"
        );

        // Update The Unstake Block for Validator
        stakeInfo.unstakeblock = block.number; //update the ustakeblock status
        // valInfo.coins = valInfo.coins.sub(unstakeamount); // sub from validator coins
        // totalDXTStake = totalDXTStake.sub(unstakeamount); // sub from total

        // Find Lowest Coins in Highest Validator List
        
        emit UnstakeDelegator(
            validator,
            delegator,
            unstakeamount,
            block.timestamp
        );

        return true;
    }

    function withdrawValidatorStaking() external  returns (bool) {
        address payable staker = msg.sender; // validator address

        Validator storage valInfo = validatorInfo[staker];

        uint256 unstakeamount = valInfo.amount; // get the stake self amount

        Delegator storage stakeInfo = stakingInfo[staker][staker];
        require(stakeInfo.unstakeblock != 0, "you have to unstake first");
        require(stakeInfo.unstakeblock + StakingLockPeriod <= block.number,"Staking haven't unlocked yet");

        uint256 staking = valInfo.amount;
        valInfo.amount = 0;
        valInfo.coins = valInfo.coins.sub(unstakeamount);
        totalDXTStake = totalDXTStake.sub(unstakeamount);

        // Get the staking amount
        stakeInfo.unstakeblock = 0;
        

        if(valInfo.amount <= 0 && valInfo.coins <=0){
           // console.log("Now Removing from Current Validators List......");
            removeFromCurrentValidatorList(staker);
        }
        valInfo.status = Status.NotExist;
        staker.transfer(staking);
        emit WithdrawValidatorStaking(staker, staking, block.timestamp);
        return true;
    }

    function withdrawDelegatorStaking(address validator)
        external
        zeroAddress
        returns (bool)
    {
        address payable staker = msg.sender; //Delegator Address

        Delegator storage stakeInfo = stakingInfo[staker][validator]; // Delegator Staking Info
        Validator storage valInfo = validatorInfo[validator]; // Validator 
        require(stakeInfo.unstakeblock != 0, "you have to unstake first");
        require(
            stakeInfo.unstakeblock + StakingLockPeriod <= block.number,
            "Staking haven't unlocked yet"
        );

        //Get The Staking Coins of Delegators
        uint256 staking = stakeInfo.amount;

        stakeInfo.amount = 0;
        // Update The Coins in Validator Record
        valInfo.coins = valInfo.coins.sub(staking);
        stakeInfo.unstakeblock = 0;

        // Update The Validator Info
        if (stakeInfo.index != valInfo.delegators.length - 1) {
            valInfo.delegators[stakeInfo.index] = valInfo.delegators[
                valInfo.delegators.length - 1
            ];
            //update index of staker
            stakingInfo[valInfo.delegators[stakeInfo.index]][validator]
                .index = stakeInfo.index;
        }

        valInfo.delegators.pop();

        // Find Lowest in Highest Validator
        uint256 lowestCoin;
        uint256 lowIdx;
        address lowValidator;
        (lowestCoin,lowIdx,lowValidator) = lowestCoinsInHighestValidator();

        // Find Highest Coins in Current Validator List
        uint256 highCoins;
        uint256 highIndex;
        address highValidator;
        (highCoins,highIndex,highValidator) = highestCoinsInCurrentValidatorsNotInTopValidator();


        if(highCoins > lowestCoin){
            highestValidators[lowIdx] = highValidator;
        }
        
        if(valInfo.coins == 0){
            removeFromCurrentValidatorList(validator);
            valInfo.status = Status.NotExist;
        }

        staker.transfer(staking);

        emit WithdrawDelegatorStaking(
            staker,
            validator,
            staking,
            block.timestamp
        );
    }

/*****************Reward Functionality********************/

    function claimValidatorReward() external zeroAddress returns(bool) {

        address payable staker = msg.sender; // validator address
        Validator storage valInfo = validatorInfo[staker];    
        require(valInfo.status != Status.NotExist && valInfo.status != Status.Jailed); // Check for Not Exist Or Jailed
        require(valInfo.income > 0, "No incomes yet.");
        uint256 rewardAmount = valInfo.income;

        staker.transfer(rewardAmount);// Transfering The Reward Amount
        valInfo.income = 0;// Reseting income of validator
        emit ValidatorClaimReward(staker,rewardAmount, block.timestamp);
        return true;
    }

   function claimDelegatorReward(address validator) external zeroAddress returns(bool) {
        address payable delegator = msg.sender; // delegator self address

        Validator storage valInfo = validatorInfo[validator];
        require(valInfo.status != Status.NotExist && valInfo.status != Status.Jailed); // Check for Not Exist Or Jailed

        Delegator storage stakeInfo = stakingInfo[delegator][validator];// Get Delegators Info
        uint staking = stakeInfo.income;

        if(stakeInfo.income<=0){
            return false; // return if income is zero 
        }

        delegator.transfer(staking); // transfer the income to delegators
        stakeInfo.income = 0; 
    
        emit DelegatorClaimReward(delegator,validator,staking,block.timestamp);
        return true;
    }


    function punish(address validator) private returns(bool){
        
        //Zero Address
        require(validator != address(0),"Zero Address");
        //Get The Validator Info to Change Status
        Validator storage valInfo = validatorInfo[validator];
        // Get Punish Record of the Validator
        PunishRecord storage punishInfo = punishRecord[validator];

        uint256 income = valInfo.income;

        if(!punishInfo.isPunished){
            punishInfo.isPunished = true;
            punishInfo.index = punishValidator.length;
            punishValidator.push(validator);

        }

        // Increment the Block Counter
        punishInfo.missedBlockCounter = punishInfo.missedBlockCounter.add(1);
         // If Cross Punish Threshold Change Status To Jail
        if(punishInfo.missedBlockCounter % punishThreshold == 0 && Status.Jailed != valInfo.status){
            //Change the Status to Jailed
            valInfo.status = Status.Jailed;
            // Logic to Distribute Income to Better Validators

            // distributeIncomeToValidator();
            // Reset the Validator Missed Block Counter
            punishInfo.missedBlockCounter  = 0;

        }

        emit PunishValidator(validator,block.timestamp);
        return true;

    }


    /**********Internal Functions**********/

    function isActiveValidator(address who) private view returns (bool) {
        for (uint256 k = 0; k < currentValidators.length; k++) {
            if (who == currentValidators[k]) {
                return true;
            }
        }
        return false;
    }

    function isTopValidator(address who) private view returns (bool) {
        for (uint256 i = 0; i < highestValidators.length; i++) {
            if (who == highestValidators[i]) {
                return true;
            }
        }
        return false;
    }

    function isDelegatorsExist(address who,address[] memory delegators) private pure returns(bool){
        for(uint k=0;k<delegators.length;k++){
            if(who == delegators[k]){
                return true;
            }
        }

        return false;
    }

    function removeFromHighestValidatorList(address val) private {
        uint256 n = highestValidators.length;
        for (uint256 k = 0; k < n && n > 1; k++) {
            if (val == highestValidators[k]) {
                if (k != n - 1) {
                    highestValidators[k] = highestValidators[n - 1];
                }
                highestValidators.pop();
                emit RemoveFromHighestValidators(val, block.timestamp);
                break;
            }
        }
    }

    function removeFromCurrentValidatorList(address val) private {
        uint256 n = currentValidators.length;
        for (uint256 i = 0; i < n && n > 1; i++) {
            if (val == currentValidators[i]) {
                if (i != n - 1) {
                    currentValidators[i] = currentValidators[n - 1];
                }
                currentValidators.pop();
                emit RemoveFromCurrentValidatorsList(val, block.timestamp);
                break;
            }
        }
    }

    function getStakingInfo(address staker, address val)
        public
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        return (
            stakingInfo[staker][val].amount,
            stakingInfo[staker][val].unstakeblock,
            stakingInfo[staker][val].index,
            stakingInfo[staker][val].income
        );
    }

    function lowestCoinsInHighestValidator() private view returns(uint256,uint256,address){

        uint256 lowestCoin = validatorInfo[highestValidators[0]].coins; //first validator coins
        uint256 lowIndex;
        address lowValidator;

            for (uint256 j = 1; j < highestValidators.length; j++) {
                if (validatorInfo[highestValidators[j]].coins < lowestCoin) {
                    lowIndex = j;
                    lowestCoin = validatorInfo[highestValidators[j]].coins;
                    lowValidator = highestValidators[j];
                   
                }
            }

            return(lowestCoin,lowIndex,lowValidator);
    }

    function highestCoinsInCurrentValidatorsNotInTopValidator() private view returns(uint256,uint256,address){

        uint256 highCoins;
        uint256 highIndex;
        address highestValidatorAddress;
        for (uint256 k = 0; k < currentValidators.length; k++) {
            if (validatorInfo[currentValidators[k]].coins > highCoins && !isTopValidator(currentValidators[k]) && validatorInfo[currentValidators[k]].status == Status.Staked) {
                highCoins = validatorInfo[currentValidators[k]].coins;
                highIndex = k;
                highestValidatorAddress = currentValidators[k];
            }
        }
        return(highCoins,highIndex,highestValidatorAddress);
    }


    function distributeRewardToDelegators(uint256 rewardAmount, address validator,uint256 totalCoins) private{

        Validator storage valInfo = validatorInfo[validator];

        if(valInfo.delegators.length < 0)
        return;
        for(uint256 j=0;j<valInfo.delegators.length;j++){
            address curr = valInfo.delegators[j];
            Delegator storage stakeInfo = stakingInfo[curr][validator];
            uint stakeamount  = stakeInfo.amount;
            
            uint256 percentageToTransfer = stakeamount.mul(100).div(totalCoins);
            //console.log("Percentage Transfer",percentageToTransfer);
            uint256 rewardDelegatorAmount = rewardAmount.mul(percentageToTransfer).div(100);
            //console.log("Reward Delegator Amount %s",rewardDelegatorAmount);

            stakeInfo.income = stakeInfo.income.add(rewardDelegatorAmount);// Reseting income of delegator
            //console.log("Delegator Income %s",stakeInfo.income);
        }
    }


    /***** Modifiers Internal Funtions*********/
    function _zeroAddress()internal view{
        require(msg.sender != address(0),"Zero Address");
    }

    /*******Getter*******/
     function getValidatorInfo(address val)
        public
        view
        returns (
            address,
            Status,
            uint256,
            uint256,
            uint256,
            uint256,
            address[] memory
        )
    {
        Validator memory v = validatorInfo[val];

        return (v.validator, v.status, v.amount, v.coins, v.income,v.TotalIncome,v.delegators);
    }
     function getDelegatorInfo(address del) public view returns(address, uint256, uint256, uint256, uint256) {
      Delegator storage d = stakingInfo[del][del];
      return(d.delegatorAddress, d.amount, d.unstakeblock, d.index, d.income);
    }
    function getCurrentValidators() public view returns (address[] memory) {
        return currentValidators;
    }

    function getBlockNumber() public view returns(uint256) {
        return block.number;
    }

    function getHighestValidators() public view returns (address[] memory) {
        return highestValidators;
    }

    function getContractBalance() public view returns (uint256) {
        return address(this).balance;
    }
}   
   