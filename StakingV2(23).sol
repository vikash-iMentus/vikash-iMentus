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
        address[] delegators;
    }

    struct Delegator {
        address delegatorAddress; // self address
        uint256 amount; // self stake
        uint256 unstakeblock; // unstakeblock = 0 means can stake if !=0 already unstake
        uint256 index; // index no represent in stakers array in Validator Struct
    }

    // Validator Address  = > Get Validator Information
    mapping(address => Validator) validatorInfo;

    mapping(address => mapping(address => Delegator)) stakingInfo;

    address[] public currentValidators; // All Validators
    address[] public highestValidators; // Only Top 21

    uint256 public totalDXTStake; //  To DXT Stake Amount

    /**********Constant**********/
    uint256 public constant minimumStakeAmount = 10 ether; // Minimum Stake DXT
    uint16 public constant MaxValidators = 3; // Total Max Validator
    uint64 public constant StakingLockPeriod = 1 seconds; // Stake Locking Period
    uint64 public constant WithdrawProfitPeriod = 2 minutes; // Withdraw Profit Period

    /**********Punish Params**********/

    uint256 public removeThreshold = 48;
    uint256 public punishThreshold = 24;

    struct PunishRecord {
        uint256 missedBlockCounter;
        uint256 index;
        bool isPunished;
    }

    mapping(address => PunishRecord) punishRecord;
    //Mapping for Block Number Tracking
    mapping(uint256 => bool) punished;
    mapping(uint256 => bool) decreased;

    enum Operations {
        Distribute,
        UpdateValidators
    }
    // Record the operations is done or not.
    mapping(uint256 => mapping(uint8 => bool)) operationsDone;

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
    event RemoveFromHighestValidators(address indexed validator, uint256 time);
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

    function stakeValidator() external payable returns (bool) {
        address staker = msg.sender;
        uint256 stakeamount = msg.value;

        //Struct Validator Variable
        Validator storage valInfo = validatorInfo[staker];

        if (stakeamount < 0) {
            return false;
        }
        // Check for Minimum Stake DXT
        require(stakeamount >= minimumStakeAmount, "Must Stake 10 or More");

        if (!isActiveValidator(staker) && Status.NotExist == valInfo.status) {
            valInfo.validator = staker;
            valInfo.status = Status.Created;
            valInfo.amount = valInfo.amount.add(stakeamount);
            valInfo.coins = valInfo.coins.add(stakeamount);
            // Update in StakingInfo
            stakingInfo[staker][staker].amount = stakingInfo[staker][staker]
                .amount
                .add(stakeamount);
            stakingInfo[staker][staker].index = valInfo.delegators.length;
        } else if (
            isActiveValidator(staker) && Status.Staked == valInfo.status
        ) {
            valInfo.amount = valInfo.amount.add(stakeamount);
            valInfo.coins = valInfo.coins.add(stakeamount);

            // Update in StakingInfo
            stakingInfo[staker][staker].amount = stakingInfo[staker][staker]
                .amount
                .add(stakeamount);
            stakingInfo[staker][staker].index = valInfo.delegators.length;
        }

        if (
            highestValidators.length < MaxValidators && !isTopValidator(staker)
        ) {
            highestValidators.push(staker); // push into highestValidator if there is space
        } else if (highestValidators.length >= MaxValidators && !isTopValidator(staker)) {
            // Find The Lowest Coins Address & Index in HighestValidators List
            uint256 lowestCoin = validatorInfo[highestValidators[0]].coins;
            uint256 lowIndex = 0;
            address validatorRemoveAddress;

            for (uint256 j = 1; j < highestValidators.length; j++) {
                if (validatorInfo[highestValidators[j]].coins < lowestCoin) {
                    validatorRemoveAddress = highestValidators[j];
                    lowIndex = j;
                    lowestCoin = validatorInfo[highestValidators[j]].coins;
                   
                }
            }

          

            if (valInfo.coins > lowestCoin) {
              
                highestValidators[lowIndex] = staker;
                if (!isActiveValidator(validatorRemoveAddress) && validatorRemoveAddress!=address(0)) {
                   
                    currentValidators.push(validatorRemoveAddress);
                }
            }
        }

        // Change the Status to Staked
        if (valInfo.status != Status.Staked) {
            valInfo.status = Status.Staked;
        }
        if (!isActiveValidator(staker)) {
            currentValidators.push(staker);
        }

        // currentValidators.push(staker);
        totalDXTStake = totalDXTStake.add(stakeamount);
        emit StakeValidator(staker, stakeamount, block.timestamp);
  

        return true;
    }

    function stakeDelegator(address validator) external payable returns (bool) {
        address staker = msg.sender; //Delegator
        uint256 stakeamount = msg.value; // Stake Amount

        if (stakeamount < 0) {
            return false;
        }
        // Struct Validator
        Validator storage valInfo = validatorInfo[validator];
        // Struct Delegator
        Delegator storage stakeInfo = stakingInfo[staker][validator];

        if (
            !isActiveValidator(validator) && valInfo.status == Status.NotExist
        ) {
            valInfo.validator = validator;
            valInfo.status = Status.Created;
            valInfo.coins = valInfo.coins.add(stakeamount);
            stakeInfo.delegatorAddress = staker;
            stakeInfo.amount = stakeInfo.amount.add(stakeamount);

            stakeInfo.index = valInfo.delegators.length;
            valInfo.delegators.push(staker);
        } else if (
            isActiveValidator(validator) && valInfo.status == Status.Staked
        ) {
            // Update Validator Coins
            valInfo.coins = valInfo.coins.add(stakeamount);
            stakeInfo.amount = stakeInfo.amount.add(stakeamount);
            stakeInfo.delegatorAddress = staker;
            stakeInfo.index = valInfo.delegators.length;
            if(valInfo.delegators.length == 0){
                valInfo.delegators.push(staker);
            } else if(!isDelegatorsExist(staker,valInfo.delegators)){
                valInfo.delegators.push(staker);
             }
            
        }

        if (
            highestValidators.length < MaxValidators &&
            !isTopValidator(validator)
        ) {
            highestValidators.push(validator); // push into highestValidator if there is space
        } else if (highestValidators.length >= MaxValidators && !isTopValidator(validator)) {
            // Find The Lowest Coins Address & Index in HighestValidators List
            uint256 lowestCoin = validatorInfo[highestValidators[0]].coins;
            uint256 lowIndex = 0;
            address validatorRemoveAddress;

            for (uint256 j = 1; j < highestValidators.length; j++) {
                if (validatorInfo[highestValidators[j]].coins < lowestCoin) {
                    validatorRemoveAddress = highestValidators[j];
                    lowIndex = j;
                    lowestCoin = validatorInfo[highestValidators[j]].coins;
                }
            }

            if (
                valInfo.coins > lowestCoin
            ) {
                if (!isTopValidator(validator)) {
                    highestValidators[lowIndex] = validator;
                }

                if (!isActiveValidator(validatorRemoveAddress) && validatorRemoveAddress != address(0)) {
                    currentValidators.push(validatorRemoveAddress);
                }
            }
        }

        // Change the Status to Staked
        if (valInfo.status != Status.Staked) {
            valInfo.status = Status.Staked;
        }
        if (!isActiveValidator(validator)) {
            currentValidators.push(validator);
        }

        // currentValidators.push(validator);
        totalDXTStake = totalDXTStake.add(stakeamount);
        emit StakeDelegator(staker, validator, stakeamount, block.timestamp);


        return true;
    }

    function unstakeValidator() external returns (bool) {
        address staker = msg.sender; //get the validator address
        //Struct Validator
        Validator storage valInfo = validatorInfo[staker];
        // Struct Delegator
        Delegator storage stakeInfo = stakingInfo[staker][staker];

        uint256 unstakeamount = valInfo.amount; // 40

        // Check for the unstakeBlock status
        require(
            stakingInfo[staker][staker].unstakeblock == 0,
            "Already in Unstaking Status"
        );
        require(unstakeamount > 0, "Don't have any stake");
        require(
            (highestValidators.length == 1) &&
                (isTopValidator(staker) || isActiveValidator(staker)),
            "You can't unstake, validator list will be empty after this operation!"
        );

        // Remove From The Total as Well as Self
        valInfo.amount = valInfo.amount.sub(unstakeamount); //0
        valInfo.coins = valInfo.coins.sub(unstakeamount); //45 - 40 => 5
        // Set The Staking Status
        stakeInfo.unstakeblock = block.number;

        totalDXTStake = totalDXTStake.sub(unstakeamount);

        // Update The Highest Validator From Current
        //uint256 highCoins = validatorInfo[currentValidators[0]].coins;
        uint256 highIndex = 0;
        address highestValidatorAddress;
        uint256 highCoins = 0;

        for (uint256 k = 0; k < currentValidators.length; k++) {
            if (validatorInfo[currentValidators[k]].coins > highCoins && !isTopValidator(currentValidators[k])) {
                highCoins = validatorInfo[currentValidators[k]].coins;
                highIndex = k;
                highestValidatorAddress = currentValidators[k];
            }
        }
        //Remove From Both List
        removeFromHighestValidatorList(staker);
        removeFromCurrentValidatorList(staker);

         if (
            !isTopValidator(highestValidatorAddress) && highestValidatorAddress !=address(0) &&
            highestValidators.length < MaxValidators
        ) {
            highestValidators.push(highestValidatorAddress);
        }

        // Change the Status of the Validator
        valInfo.status = Status.NotExist;
        emit UnstakeValidator(staker, unstakeamount, block.timestamp);

        return true;
    }

    function unstakeDelegators(address validator) external returns (bool) {
        address delegator = msg.sender;

        // Struct Delegator
        Delegator storage stakeInfo = stakingInfo[delegator][validator];
        Validator storage valInfo = validatorInfo[validator];

        uint256 unstakeamount = stakeInfo.amount; // get the staking info

        require(stakeInfo.unstakeblock == 0, "Already in unstaking status");
        require(unstakeamount > 0, "don't have any stake");
        require(
            !(highestValidators.length == 1),
            "You can't unstake, validator list will be empty after this operation!"
        );

        

        stakeInfo.unstakeblock = block.number; //update the ustakeblock status
        // stakeInfo.index = 0;

        valInfo.coins = valInfo.coins.sub(unstakeamount); // sub from validator coins
        totalDXTStake = totalDXTStake.sub(unstakeamount); // sub from total

        // Find Lowest Coins in Highest Validator List
        uint256 lowestCoin = validatorInfo[highestValidators[0]].coins;
        uint256 lowIndex = 0;
        address lowValidator;

        for (uint256 j = 1; j < highestValidators.length; j++) {
            if (validatorInfo[highestValidators[j]].coins < lowestCoin) {
                lowestCoin = validatorInfo[highestValidators[j]].coins;
                lowIndex = j;
                lowValidator = highestValidators[j];
            }
        }

        // Find Highest Coins in Current Validator List
        uint256 highCoins = validatorInfo[currentValidators[0]].coins;
        uint256 highIndex = 0;
        address highestValidatorAddress;

        for (uint256 k = 1; k < currentValidators.length; k++) {
            if (validatorInfo[currentValidators[k]].coins > highCoins) {
                highCoins = validatorInfo[currentValidators[k]].coins;
                highIndex = k;
                highestValidatorAddress = currentValidators[k];
            }
        }

        if (lowestCoin < highCoins) {
            // Push that into Highest Validator From Current Validator
            if (!isTopValidator(highestValidatorAddress) && highestValidatorAddress !=address(0)) {
                highestValidators[lowIndex] = highestValidatorAddress;
            }
            // Update in Currernt Validator From Highest Validators
            if (!isActiveValidator(lowValidator) && lowValidator!=address(0)) {
                currentValidators[highIndex] = lowValidator;
            }
        }
        emit UnstakeDelegator(
            validator,
            delegator,
            unstakeamount,
            block.timestamp
        );

        return true;
    }
    function isDelegatorsExist(address who,address[] memory delegators) private pure returns(bool){
        for(uint k=0;k<delegators.length;k++){
            if(who == delegators[k]){
                return true;
            }
        }

        return false;
    }

    function withdrawValidatorStaking() external returns (bool) {
        address payable staker = msg.sender;
        // Validator storage valInfo = validatorInfo[staker];
        Delegator storage stakeInfo = stakingInfo[staker][staker];
        require(stakeInfo.unstakeblock != 0, "you have to unstake first");
        require(
            stakeInfo.unstakeblock + StakingLockPeriod <= block.number,
            "Staking haven't unlocked yet"
        );

        // Get the staking amount
        uint256 staking = stakeInfo.amount;
        stakeInfo.unstakeblock = 0;
        stakeInfo.amount = 0;
        stakeInfo.index = 0;
        staker.transfer(staking);
        emit WithdrawValidatorStaking(staker, staking, block.timestamp);
    }

    function withdrawDelegatorStaking(address validator)
        external
        returns (bool)
    {
        address payable staker = msg.sender;

        Delegator storage stakeInfo = stakingInfo[staker][validator];
        Validator storage valInfo = validatorInfo[validator];
        require(stakeInfo.unstakeblock != 0, "you have to unstake first");
        require(
            stakeInfo.unstakeblock + StakingLockPeriod <= block.number,
            "Staking haven't unlocked yet"
        );

        //Get The Staking Coins of Delegators
        uint256 staking = stakeInfo.amount;

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

        stakeInfo.unstakeblock = 0;
        stakeInfo.amount = 0;
        staker.transfer(staking);

        emit WithdrawDelegatorStaking(
            staker,
            validator,
            staking,
            block.timestamp
        );
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

    function getValidatorInfo(address val)
        public
        view
        returns (
            address,
            Status,
            uint256,
            uint256,
            address[] memory
        )
    {
        Validator memory v = validatorInfo[val];

        return (v.validator, v.status, v.amount, v.coins, v.delegators);
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
            uint256
        )
    {
        return (
            stakingInfo[staker][val].amount,
            stakingInfo[staker][val].unstakeblock,
            stakingInfo[staker][val].index
        );
    }

    /*******Getter*******/
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

