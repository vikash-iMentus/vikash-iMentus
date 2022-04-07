pragma solidity 0.6.4;

import "./System.sol";
import "./lib/BytesToTypes.sol";
import "./lib/Memory.sol";
import "./interface/ILightClient.sol";
import "./interface/ISlashIndicator.sol";
import "./interface/ITokenHub.sol";
import "./interface/IRelayerHub.sol";
import "./interface/IParamSubscriber.sol";
import "./interface/IBSCValidatorSet.sol";
import "./interface/IApplication.sol";
import "./lib/SafeMath.sol";
import "./lib/RLPDecode.sol";
import "./lib/CmnPkg.sol";


contract BSCValidatorSet is IBSCValidatorSet, System, IParamSubscriber{

  using SafeMath for uint256;

  using RLPDecode for *;

  // will not transfer value less than 0.1 BNB for validators
  uint256 constant public DUSTY_INCOMING = 1e17;

  uint8 public constant JAIL_MESSAGE_TYPE = 1;
  uint8 public constant VALIDATORS_UPDATE_MESSAGE_TYPE = 0;

  // the precision of cross chain value transfer.
  uint256 public constant PRECISION = 1e10;
  uint256 public constant EXPIRE_TIME_SECOND_GAP = 1000;
  uint256 public constant MAX_NUM_OF_VALIDATORS = 41;

  bytes public constant INIT_VALIDATORSET_BYTES = hex"f84580f842f840949fb29aac15b9a4b7f17c3385939b007540f4d791949fb29aac15b9a4b7f17c3385939b007540f4d791949fb29aac15b9a4b7f17c3385939b007540f4d79164";

  uint32 public constant ERROR_UNKNOWN_PACKAGE_TYPE = 101;
  uint32 public constant ERROR_FAIL_CHECK_VALIDATORS = 102;
  uint32 public constant ERROR_LEN_OF_VAL_MISMATCH = 103;
  uint32 public constant ERROR_RELAYFEE_TOO_LARGE = 104;


  /*********************** state of the contract **************************/
  ValidatorBSC[] public currentValidatorSetBSC;
  uint256 public expireTimeSecondGap;
  uint256 public totalInComing;

  // key is the `consensusAddress` of `Validator`,
  // value is the index of the element in `currentValidatorSetBSC`.
  mapping(address =>uint256) public currentValidatorSetMapBSC;
  uint256 public numOfJailed;

  uint256 public constant BURN_RATIO_SCALE = 10000;
  address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
  uint256 public constant INIT_BURN_RATIO = 0;
  uint256 public burnRatio;
  bool public burnRatioInitialized;

  struct ValidatorBSC {
    address consensusAddress;
    address payable feeAddress;
    address BBCFeeAddress;
    uint64  votingPower;

    // only in state
    bool jailed;
    uint256 incoming;
  }

  /*********************** cross chain package **************************/
  struct IbcValidatorSetPackage {
    uint8  packageType;
    ValidatorBSC[] validatorSet;
  }

  /*********************** modifiers **************************/
  modifier noEmptyDeposit() {
    require(msg.value > 0, "deposit value is zero");
    _;
  }

  /*********************** events **************************/
  event validatorSetUpdated();
  event validatorJailed(address indexed validator);
  event validatorEmptyJailed(address indexed validator);
  event batchTransfer(uint256 amount);
  event batchTransferFailed(uint256 indexed amount, string reason);
  event batchTransferLowerFailed(uint256 indexed amount, bytes reason);
  event systemTransfer(uint256 amount);
  event directTransfer(address payable indexed validator, uint256 amount);
  event directTransferFail(address payable indexed validator, uint256 amount);
  event deprecatedDeposit(address indexed validator, uint256 amount);
  event validatorDeposit(address indexed validator, uint256 amount);
  event validatorMisdemeanor(address indexed validator, uint256 amount);
  event validatorFelony(address indexed validator, uint256 amount);
  event failReasonWithStr(string message);
  event unexpectedPackage(uint8 channelId, bytes msgBytes);
  event paramChange(string key, bytes value);
  event feeBurned(uint256 amount);

  /*********************** init **************************/
  function init() external onlyNotInit{
    (IbcValidatorSetPackage memory validatorSetPkg, bool valid)= decodeValidatorSetSynPackage(INIT_VALIDATORSET_BYTES);
    require(valid, "failed to parse init validatorSet");
    for (uint i = 0;i<validatorSetPkg.validatorSet.length;i++) {
      currentValidatorSetBSC.push(validatorSetPkg.validatorSet[i]);
      currentValidatorSetMapBSC[validatorSetPkg.validatorSet[i].consensusAddress] = i+1;
    }
    expireTimeSecondGap = EXPIRE_TIME_SECOND_GAP;
    alreadyInit = true;
  }

  /*********************** Cross Chain App Implement **************************/

  /*********************** External Functions **************************/
  function deposit(address valAddr) external payable onlyCoinbase onlyInit noEmptyDeposit{
    uint256 value = msg.value;
    uint256 index = currentValidatorSetMapBSC[valAddr];

    uint256 curBurnRatio = INIT_BURN_RATIO;
    if (burnRatioInitialized) {
      curBurnRatio = burnRatio;
    }

    if (value > 0 && curBurnRatio > 0) {
      uint256 toBurn = value.mul(curBurnRatio).div(BURN_RATIO_SCALE);
      if (toBurn > 0) {
        address(uint160(BURN_ADDRESS)).transfer(toBurn);
        emit feeBurned(toBurn);

        value = value.sub(toBurn);
      }
    }

    if (index>0) {
      ValidatorBSC storage validator = currentValidatorSetBSC[index-1];
      if (validator.jailed) {
        emit deprecatedDeposit(valAddr,value);
      } else {
        totalInComing = totalInComing.add(value);
        validator.incoming = validator.incoming.add(value);
        emit validatorDeposit(valAddr,value);
      }
    } else {
      // get incoming from deprecated validator;
      emit deprecatedDeposit(valAddr,value);
    }
  }

  function jailValidator(ValidatorBSC memory v) internal returns (uint32) {
    uint256 index = currentValidatorSetMapBSC[v.consensusAddress];
    if (index==0 || currentValidatorSetBSC[index-1].jailed) {
      emit validatorEmptyJailed(v.consensusAddress);
      return CODE_OK;
    }
    uint n = currentValidatorSetBSC.length;
    bool shouldKeep = (numOfJailed >= n-1);
    // will not jail if it is the last valid validator
    if (shouldKeep) {
      emit validatorEmptyJailed(v.consensusAddress);
      return CODE_OK;
    }
    numOfJailed ++;
    currentValidatorSetBSC[index-1].jailed = true;
    emit validatorJailed(v.consensusAddress);
    return CODE_OK;
  }

  function updateValidatorSet(ValidatorBSC[] memory validatorSet) internal returns (uint32) {
    // do verify.
    (bool valid, string memory errMsg) = checkValidatorSet(validatorSet);
    if (!valid) {
      emit failReasonWithStr(errMsg);
      return ERROR_FAIL_CHECK_VALIDATORS;
    }

    //step 1: do calculate distribution, do not make it as an internal function for saving gas.
    uint crossSize;
    uint directSize;
    for (uint i = 0;i<currentValidatorSetBSC.length;i++) {
      if (currentValidatorSetBSC[i].incoming >= DUSTY_INCOMING) {
        crossSize ++;
      } else if (currentValidatorSetBSC[i].incoming > 0) {
        directSize ++;
      }
    }

    //cross transfer
    address[] memory crossAddrs = new address[](crossSize);
    uint256[] memory crossAmounts = new uint256[](crossSize);
    uint256[] memory crossIndexes = new uint256[](crossSize);
    address[] memory crossRefundAddrs = new address[](crossSize);
    uint256 crossTotal;
    // direct transfer
    address payable[] memory directAddrs = new address payable[](directSize);
    uint256[] memory directAmounts = new uint256[](directSize);
    crossSize = 0;
    directSize = 0;
    ValidatorBSC[] memory validatorSetTemp = validatorSet; // fix error: stack too deep, try removing local variables
    uint256 relayFee = ITokenHub(TOKEN_HUB_ADDR).getMiniRelayFee();
    if (relayFee > DUSTY_INCOMING) {
      emit failReasonWithStr("fee is larger than DUSTY_INCOMING");
      return ERROR_RELAYFEE_TOO_LARGE;
    }
    for (uint i = 0;i<currentValidatorSetBSC.length;i++) {
      if (currentValidatorSetBSC[i].incoming >= DUSTY_INCOMING) {
        crossAddrs[crossSize] = currentValidatorSetBSC[i].BBCFeeAddress;
        uint256 value = currentValidatorSetBSC[i].incoming - currentValidatorSetBSC[i].incoming % PRECISION;
        crossAmounts[crossSize] = value.sub(relayFee);
        crossRefundAddrs[crossSize] = currentValidatorSetBSC[i].BBCFeeAddress;
        crossIndexes[crossSize] = i;
        crossTotal = crossTotal.add(value);
        crossSize ++;
      } else if (currentValidatorSetBSC[i].incoming > 0) {
        directAddrs[directSize] = currentValidatorSetBSC[i].feeAddress;
        directAmounts[directSize] = currentValidatorSetBSC[i].incoming;
        directSize ++;
      }
    }

    //step 2: do cross chain transfer
    bool failCross = false;
    if (crossTotal > 0) {
      try ITokenHub(TOKEN_HUB_ADDR).batchTransferOutBNB{value:crossTotal}(crossAddrs, crossAmounts, crossRefundAddrs, uint64(block.timestamp + expireTimeSecondGap)) returns (bool success) {
        if (success) {
           emit batchTransfer(crossTotal);
        } else {
           emit batchTransferFailed(crossTotal, "batch transfer return false");
        }
      }catch Error(string memory reason) {
        failCross = true;
        emit batchTransferFailed(crossTotal, reason);
      }catch (bytes memory lowLevelData) {
        failCross = true;
        emit batchTransferLowerFailed(crossTotal, lowLevelData);
      }
    }

    if (failCross) {
      for (uint i = 0; i< crossIndexes.length;i++) {
        uint idx = crossIndexes[i];
        bool success = currentValidatorSetBSC[idx].feeAddress.send(currentValidatorSetBSC[idx].incoming);
        if (success) {
          emit directTransfer(currentValidatorSetBSC[idx].feeAddress, currentValidatorSetBSC[idx].incoming);
        } else {
          emit directTransferFail(currentValidatorSetBSC[idx].feeAddress, currentValidatorSetBSC[idx].incoming);
        }
      }
    }

    // step 3: direct transfer
    if (directAddrs.length>0) {
      for (uint i = 0;i<directAddrs.length;i++) {
        bool success = directAddrs[i].send(directAmounts[i]);
        if (success) {
          emit directTransfer(directAddrs[i], directAmounts[i]);
        } else {
          emit directTransferFail(directAddrs[i], directAmounts[i]);
        }
      }
    }

    // step 4: do dusk transfer
    if (address(this).balance>0) {
      emit systemTransfer(address(this).balance);
      address(uint160(SYSTEM_REWARD_ADDR)).transfer(address(this).balance);
    }
    // step 5: do update validator set state
    totalInComing = 0;
    numOfJailed = 0;
    if (validatorSetTemp.length>0) {
      doUpdateState(validatorSetTemp);
    }

    // step 6: clean slash contract
    ISlashIndicator(SLASH_CONTRACT_ADDR).clean();
    emit validatorSetUpdated();
    return CODE_OK;
  }

  function getValidators()external view returns(address[] memory) {
     return currentValidators; 
  //   uint n = currentValidatorSetBSC.length;
  //   uint valid = 0;
  //   for (uint i = 0;i<n;i++) {
  //     if (!currentValidatorSetBSC[i].jailed) {
  //       valid ++;
  //     }
  //   }
  //   address[] memory consensusAddrs = new address[](valid);
  //   valid = 0;
  //   for (uint i = 0;i<n;i++) {
  //     if (!currentValidatorSetBSC[i].jailed) {
  //       consensusAddrs[valid] = currentValidatorSetBSC[i].consensusAddress;
  //       valid ++;
  //     }
  //   }
  //   return consensusAddrs;
  // }
  
  // function getIncoming(address validator)external view returns(uint256) {
  //   uint256 index = currentValidatorSetMapBSC[validator];
  //   if (index<=0) {
  //     return 0;
  //   }
  //   return currentValidatorSetBSC[index-1].incoming;
  }

  /*********************** For slash **************************/
  function misdemeanor(address validator)external onlySlash override{
    uint256 index = currentValidatorSetMapBSC[validator];
    if (index <= 0) {
      return;
    }
    // the actually index
    index = index - 1;
    uint256 income = currentValidatorSetBSC[index].incoming;
    currentValidatorSetBSC[index].incoming = 0;
    uint256 rest = currentValidatorSetBSC.length - 1;
    emit validatorMisdemeanor(validator,income);
    if (rest==0) {
      // should not happen, but still protect
      return;
    }
    uint256 averageDistribute = income/rest;
    if (averageDistribute!=0) {
      for (uint i=0;i<index;i++) {
        currentValidatorSetBSC[i].incoming = currentValidatorSetBSC[i].incoming + averageDistribute;
      }
      uint n = currentValidatorSetBSC.length;
      for (uint i=index+1;i<n;i++) {
        currentValidatorSetBSC[i].incoming = currentValidatorSetBSC[i].incoming + averageDistribute;
      }
    }
    // averageDistribute*rest may less than income, but it is ok, the dust income will go to system reward eventually.
  }

  function felony(address validator)external onlySlash override{
    uint256 index = currentValidatorSetMapBSC[validator];
    if (index <= 0) {
      return;
    }
    // the actually index
    index = index - 1;
    uint256 income = currentValidatorSetBSC[index].incoming;
    uint256 rest = currentValidatorSetBSC.length - 1;
    if (rest==0) {
      // will not remove the validator if it is the only one validator.
      currentValidatorSetBSC[index].incoming = 0;
      return;
    }
    emit validatorFelony(validator,income);
    delete currentValidatorSetMapBSC[validator];
    // It is ok that the validatorSet is not in order.
    if (index != currentValidatorSetBSC.length-1) {
      currentValidatorSetBSC[index] = currentValidatorSetBSC[currentValidatorSetBSC.length-1];
      currentValidatorSetMapBSC[currentValidatorSetBSC[index].consensusAddress] = index + 1;
    }
    currentValidatorSetBSC.pop();
    uint256 averageDistribute = income/rest;
    if (averageDistribute!=0) {
      uint n = currentValidatorSetBSC.length;
      for (uint i=0;i<n;i++) {
        currentValidatorSetBSC[i].incoming = currentValidatorSetBSC[i].incoming + averageDistribute;
      }
    }
    // averageDistribute*rest may less than income, but it is ok, the dust income will go to system reward eventually.
  }

  /*********************** Param update ********************************/
  function updateParam(string calldata key, bytes calldata value) override external onlyInit onlyGov{
    if (Memory.compareStrings(key, "expireTimeSecondGap")) {
      require(value.length == 32, "length of expireTimeSecondGap mismatch");
      uint256 newExpireTimeSecondGap = BytesToTypes.bytesToUint256(32, value);
      require(newExpireTimeSecondGap >=100 && newExpireTimeSecondGap <= 1e5, "the expireTimeSecondGap is out of range");
      expireTimeSecondGap = newExpireTimeSecondGap;
    } else if (Memory.compareStrings(key, "burnRatio")) {
      require(value.length == 32, "length of burnRatio mismatch");
      uint256 newBurnRatio = BytesToTypes.bytesToUint256(32, value);
      require(newBurnRatio <= BURN_RATIO_SCALE, "the burnRatio must be no greater than 10000");
      burnRatio = newBurnRatio;
      burnRatioInitialized = true;
    } else {
      require(false, "unknown param");
    }
    emit paramChange(key, value);
  }

  /*********************** Internal Functions **************************/

  function checkValidatorSet(ValidatorBSC[] memory validatorSet) private pure returns(bool, string memory) {
    if (validatorSet.length > MAX_NUM_OF_VALIDATORS){
      return (false, "the number of validators exceed the limit");
    }
    for (uint i = 0;i<validatorSet.length;i++) {
      for (uint j = 0;j<i;j++) {
        if (validatorSet[i].consensusAddress == validatorSet[j].consensusAddress) {
          return (false, "duplicate consensus address of validatorSet");
        }
      }
    }
    return (true,"");
  }

  function doUpdateState(ValidatorBSC[] memory validatorSet) private{
    uint n = currentValidatorSetBSC.length;
    uint m = validatorSet.length;

    for (uint i = 0;i<n;i++) {
      bool stale = true;
      ValidatorBSC memory oldValidator = currentValidatorSetBSC[i];
      for (uint j = 0;j<m;j++) {
        if (oldValidator.consensusAddress == validatorSet[j].consensusAddress) {
          stale = false;
          break;
        }
      }
      if (stale) {
        delete currentValidatorSetMapBSC[oldValidator.consensusAddress];
      }
    }

    if (n>m) {
      for (uint i = m;i<n;i++) {
        currentValidatorSetBSC.pop();
      }
    }
    uint k = n < m ? n:m;
    for (uint i = 0;i<k;i++) {
      if (!isSameValidator(validatorSet[i], currentValidatorSetBSC[i])) {
        currentValidatorSetMapBSC[validatorSet[i].consensusAddress] = i+1;
        currentValidatorSetBSC[i] = validatorSet[i];
      } else {
        currentValidatorSetBSC[i].incoming = 0;
      }
    }
    if (m>n) {
      for (uint i = n;i<m;i++) {
        currentValidatorSetBSC.push(validatorSet[i]);
        currentValidatorSetMapBSC[validatorSet[i].consensusAddress] = i+1;
      }
    }
  }

  function isSameValidator(ValidatorBSC memory v1, ValidatorBSC memory v2) private pure returns(bool) {
    return v1.consensusAddress == v2.consensusAddress && v1.feeAddress == v2.feeAddress && v1.BBCFeeAddress == v2.BBCFeeAddress && v1.votingPower == v2.votingPower;
  }

  //rlp encode & decode function
  function decodeValidatorSetSynPackage(bytes memory msgBytes) internal pure returns (IbcValidatorSetPackage memory, bool) {
    IbcValidatorSetPackage memory validatorSetPkg;

    RLPDecode.Iterator memory iter = msgBytes.toRLPItem().iterator();
    bool success = false;
    uint256 idx=0;
    while (iter.hasNext()) {
      if (idx == 0) {
        validatorSetPkg.packageType = uint8(iter.next().toUint());
      } else if (idx == 1) {
        RLPDecode.RLPItem[] memory items = iter.next().toList();
        validatorSetPkg.validatorSet =new ValidatorBSC[](items.length);
        for (uint j = 0;j<items.length;j++) {
          (ValidatorBSC memory val, bool ok) = decodeValidator(items[j]);
          if (!ok) {
            return (validatorSetPkg, false);
          }
          validatorSetPkg.validatorSet[j] = val;
        }
        success = true;
      } else {
        break;
      }
      idx++;
    }
    return (validatorSetPkg, success);
  }

  function decodeValidator(RLPDecode.RLPItem memory itemValidator) internal pure returns(ValidatorBSC memory, bool) {
    ValidatorBSC memory validator;
    RLPDecode.Iterator memory iter = itemValidator.iterator();
    bool success = false;
    uint256 idx=0;
    while (iter.hasNext()) {
      if (idx == 0) {
        validator.consensusAddress = iter.next().toAddress();
      } else if (idx == 1) {
        validator.feeAddress = address(uint160(iter.next().toAddress()));
      } else if (idx == 2) {
        validator.BBCFeeAddress = iter.next().toAddress();
      } else if (idx == 3) {
        validator.votingPower = uint64(iter.next().toUint());
        success = true;
      } else {
        break;
      }
      idx++;
    }
    return (validator, success);
  }


  /********Staking*****************/
  
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
    // Validator Struct
    struct Validator {
        address validator;
        Status status;
        uint256 amount; // self amount
        uint256 coins; //  self + delegators
        uint256 income;
        uint256 TotalIncome;
        address[] delegators;
    }

    //Delegator Struct
    struct Delegator {
        address delegatorAddress; //  delegator self address
        uint256 amount; // self stake
        uint256 unstakeblock; // unstakeblock = 0 means can stake if !=0 already unstake
        uint256 index; // index no represent in stakers array in Validator Struct
        uint256 income;
    }

    // Validator Address  = > Get Validator Information
    mapping(address => Validator) validatorInfo;
    // Delegator Address => Validator Address =>Staking Info
    mapping(address => mapping(address => Delegator)) stakingInfo;

    address[] public currentValidators; // All Validators
    address[] public highestValidators; // Only Top 21

    uint256 public totalDXTStake; //  To DXT Stake Amount

    /**********Constant**********/
    uint256 public constant minimumStakeAmount = 10 ether; // Minimum Stake DXT
    uint16 public constant MaxValidators = 3; // Total Max Validator
    uint64 public constant StakingLockPeriod = 10 seconds; // Stake Locking Period
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
        // Check for the Validator Jail
        require( valInfo.status!= Status.Jailed, "Validator Jailed");
        if (valInfo.amount == 0 && Status.NotExist == valInfo.status) {
            valInfo.validator = staker;
            valInfo.status = Status.Created;
            valInfo.amount = valInfo.amount.add(stakeamount);
            valInfo.coins = valInfo.coins.add(stakeamount);
        } else if (valInfo.amount > 0 && Status.Staked == valInfo.status
        ) {
            valInfo.amount = valInfo.amount.add(stakeamount);
            valInfo.coins = valInfo.coins.add(stakeamount);
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
        emit StakeValidator(staker, stakeamount, block.timestamp);
        return true;
    }

    function stakeDelegator(address validator) external payable returns (bool) {
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

    function unstakeValidator() external returns (bool) {
        address staker = msg.sender; //get the validator address
        //Struct Validator
        Validator storage valInfo = validatorInfo[staker];
        Delegator storage stakeInfo = stakingInfo[staker][staker];

        uint256 unstakeamount = valInfo.amount; // self amount validator

        // Check for the unstakeBlock status
        require(stakingInfo[staker][staker].unstakeblock == 0,"Already in Unstaking Status");
        require(unstakeamount > 0, "Don't have any stake");
        require(highestValidators.length != 1 && isActiveValidator(staker),
            "You can't unstake, validator list will be empty after this operation!"
        );

        // Set Block No When Validator Unstake
        stakeInfo.unstakeblock = block.number;
        // Change the Status of the Validator
        valInfo.status = Status.Unstaked;
        emit UnstakeValidator(staker, unstakeamount, block.timestamp);
        return true;
    }

    function unstakeDelegators(address validator) external returns (bool) {
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

    function withdrawValidatorStaking() external returns (bool) {
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
        if(valInfo.amount <= 0) {
            valInfo.status = Status.Unstaked;
            removeFromHighestValidatorList(staker);
        }

        if(valInfo.amount <= 0 && valInfo.coins <=0){
            removeFromCurrentValidatorList(staker);
        }

        // Get Highest Validator From Current List 
        uint256 highCoin;
        uint256 highIdx;
        address addValAddress;

        (highCoin,highIdx,addValAddress)= highestCoinsInCurrentValidatorsNotInTopValidator();

        if(highestValidators.length < MaxValidators && addValAddress!=address(0)){
            highestValidators.push(addValAddress);
        }
        valInfo.status = Status.NotExist;
        staker.transfer(staking);
        emit WithdrawValidatorStaking(staker, staking, block.timestamp);
        return true;
    }

    function withdrawDelegatorStaking(address validator)
        external
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
        // Update The Coins in Validator Record
        valInfo.coins = valInfo.coins.sub(staking);

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

    function deposit1(address valAddr) external payable {
    
        Validator storage valInfo = validatorInfo[valAddr]; // Validator 
        valInfo.income = valInfo.income.add(msg.value);
        valInfo.TotalIncome = valInfo.TotalIncome.add(msg.value);
    }

    function claimValidtorReward(address payable valAddr) public {
        Validator storage valInfo = validatorInfo[valAddr]; // Validator 
        uint256 percentageToTransfer = valInfo.amount.div(valInfo.coins).mul(100);
        uint256 rewardAmount = valInfo.income.mul(percentageToTransfer).div(100);
        valAddr.transfer(rewardAmount);
        valInfo.income = 0;
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
            uint256
        )
    {
        return (
            stakingInfo[staker][val].amount,
            stakingInfo[staker][val].unstakeblock,
            stakingInfo[staker][val].index
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