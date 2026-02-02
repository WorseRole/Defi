// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";


contract MetaNodeTStake is 
Initializable, 
UUPSUpgradeable, 
PausableUpgradeable, 
AccessControlUpgradeable {
    using SafeERC20 for IERC20;
    using Address for address;
    using Math for uint256;

    // ================ INVARIANTS：不可变变量的定义 ================
    bytes32 public constant ADMIN_ROLE = keccak256("admin_role");
    bytes32 public constant UPGRADE_ROLE = keccak256("upgrade_role");

    uint256 public constant ETH_PID = 0;

    // ================ DATA STRUCTURE：数据结构的定义 ================
    /*
        Basically, any point in time, the amount of MetaNodes entitled to a user but is pending to be distributed is:

    pending MetaNode = (user.stAmount * pool.accMetaNodePerST) - user.finishedMetaNode

    Whenever a user deposits or withdraws staking tokens to a pool. Here's what happens:
    1. The pool's `accMetaNodePerST` (and `lastRewardBlock`) gets updated.
    2. User receives the pending MetaNode sent to his/her address.
    3. User's `stAmount` gets updated.
    4. User's `finishedMetaNode` gets updated.

    基本上，在任何时间点上，用户有权获得但尚未分配的MetaNode数量为：
    待领取的MetaNode = (user.stAmount * pool.accMetaNodePerST) - user.finishedMetaNode
    每当用户向池中存入或提取质押代币时，会发生以下情况：
    1. 池的`accMetaNodePerST`（和`lastRewardBlock`）会被更新。
    2. 用户收到待领取的MetaNode，发送到他的地址。
    3. 用户的`stAmount`会被更新。
    4. 用户的`finishedMetaNode`会被更新。
    
    */
    struct Pool {

        // Address of staking token
        // 质押代币的地址
        address stTokenAddress;

        // Weight of Pool
        // 不同资金池所占的权重
        uint256 poolWeight;

        // last block number that MetaNodes distribution occurs for pool
        // 上一次MetaNode分配发生的区块编号
        uint256 lastRewardBlock;

        // Accmulated MetaNodes per stabking token of pool
        // 质押 1个ETH 经过1个区块高度，能拿到 n 个MetaNode
        uint256 accMetaNodePerST;

        // Staking token amount
        // 质押代币的数量
        uint256 stTokenAmount;

        // Min staking amount;
        // 最小质押数量
        uint256 minDepositAmount;

        // Withdraw locked blocks
        // Unstake locked blocks 解质押锁定的区块高度
        uint256 unstakeLockedBlocks;
    }

    struct UnstakeRequest {
        // Request withdraw amount
        // 用户取消质押的代币数量，要取出多少个 token
        uint256 amount;

        // The blocks when the request withdraw amount can be released
        // 解质押的区块高度
        uint256 unblockBlocks;
    }

    struct User {
        // 记录用户相对每个资金池 的质押记录
        // Staking token amount that user provided
        // 用户在当前资金池，质押的代币数量
        uint256 stAmount;

        // Finished distributed MetaNodes to user 最终 MetaNode 得到的数量
        // 用户在当前资金池，已经领取的 MetaNode 数量
        uint256 finishedMetaNode;

        // Pending to claim MetaNode 当前可取数量
        // 用户在当前资金池，当前可领取的 MetaNode 数量
        uint256 pendingMetaNode;

        // Withdraw request list
        // 用户在当前资金池，取消质押的记录
        UnstakeRequest[] request;
    }

    
    // ================ STATE VARIABLES：状态变量的定义 ================
    // First block that MetaNodeStake will start from
    // 质押开始区块高度
    uint256 public startBlock;

    // First block that MetaNodeStake will end from
    // 质押结束区块高度
    uint256 public endBlock;

    // MetaNode token reward per block
    // 每个区块高度，MetaNode 的奖励数量
    uint256 public MetaNodePerBlock;

    // Pause the withdraw function
    // 是否暂停提现
    bool public withdrawPaused;

    // Pause the claim function
    // 是否暂停领取
    bool public claimPaused;

    // MetaNode token
    // MetaNode 代币地址
    IERC20 public MetaNode;

    // Total pool weight / Sum of all pool weights
    // 所有资金池的权重之和
    uint256 public totalPoolWeight;

    // pool id => user address => user info
    // 资金池数组
    Pool[] public pool;

    // 资金池数组  资金池 id => 用户地址 => 用户信息
    mapping(uint256 => mapping(address => User)) public user;

    // ================ EVENTS：事件的定义 ================
    
    // MetaNode 代币地址变更事件
    event SetMetaNode(IERC20 indexed MetaNode);

    // PauseWithdraw: 暂停提现事件
    event PauseWithdraw();

    // UnpauseWithdraw: 取消暂停提现事件
    event UnpauseWithdraw();

    // PauseClaim: 暂停领取事件
    event PauseClaim();

    // UnpauseClaim: 取消暂停领取事件
    event UnpauseClaim();

    // 设置质押开始区块高度事件
    event SetStartBlock(uint256 indexed startBlock);

    // 设置质押结束区块高度事件
    event SetEndBlock(uint256 indexed endBlock);

    // 设置每个区块高度 MetaNode 奖励数量事件
    event SetMetaNodePerBlock(uint256 indexed MetaNodePerBlock);

    // 添加资金池事件
    event AddPool (
        address indexed stTokenAddress,
        uint256 indexed poolweight,
        uint256 indexed lastRewardBlock,
        uint256 minDepositAmount,
        uint256 unstakeLockBlocks
    );

    // 更新资金池信息事件
    event UpdatePoolInfo (
        uint256 indexed poolId,
        uint256 indexed minDepositAmount,
        uint256 indexed unstakeLockBlocks
    );

    // 设置资金池权重事件
    event SetPoolWeight (
        uint256 indexed poolId,
        uint256 indexed oldWeight,
        uint256 totalPoolWeight
    );

    // 更新资金池事件
    event UpdatePool (
        uint256 indexed poolId,
        uint256 indexed lastRewardBlock,
        uint256 totalMetaNode
    );

    // 用户存入质押代币事件
    event Deposit (
        address indexed user,
        uint256 indexed poolId,
        uint256 amount
    );

    // 用户提取质押代币事件
    event Withdraw (
        address indexed user,
        uint256 indexed poolId,
        uint256 amount,
        uint256 indexed blockNumber
    );

    // 用户领取 MetaNode 代币事件
    event Claim (
        address indexed user,
        uint256 indexed poolId,
        uint256 MetaNodeReward
    );

    //=============== MODIFIERS：修饰符的定义 ================

    modifier checkPid(uint256 _pid) {
        require(_pid < pool.length, "invalid pid");
        _;
    }

    modifier whenNotClaimPaused() {
        require(!claimPaused, "claim is paused");
        _;
    }

    modifier whenNotWithdrawPaused() {
        require(!withdrawPaused, "withdraw is paused");
        _;
    }

    /**
    * @dev 初始化合约
    * @param _MetaNode MetaNode 代币地址
    * @param _startBlock 质押开始区块高度
    * @param _endBlock 质押结束区块高度
    * @param _MetaNodePerBlock 每个区块高度 MetaNode 奖励数量
    */
    function initialize(
        IERC20 _MetaNode, 
        uint256 _startBlock, 
        uint256 _endBlock, 
        uint256 _MetaNodePerBlock) public initializer {
            
            require(
                _startBlock <= _endBlock && _MetaNodePerBlock > 0,
                "invalid parameters"
            );

            __AccessControl_init();
            __UUPSUpgradeable_init();
            _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
            _grantRole(ADMIN_ROLE, msg.sender);
            _grantRole(UPGRADE_ROLE, msg.sender);

            setMetaNode(_MetaNode);

            startBlock = _startBlock;
            endBlock = _endBlock;
            MetaNodePerBlock = _MetaNodePerBlock;
    }

    // UUPSUpgradeable 合约的授权函数
    // onlyRole 修饰符，只有拥有 UPGRADE_ROLE 角色的地址才能升级合约
    // 重写 _authorizeUpgrade 函数，添加 onlyRole(UPGRADE_ROLE) 修饰符
    // 只有拥有 UPGRADE_ROLE 角色的地址才能升级合约
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(UPGRADE_ROLE) {}


    // ================ ADMIN FUNCTIONS：管理员函数的定义 ================

    // 设置 MetaNode 代币地址
    function setMetaNode(IERC20 _MetaNode) public onlyRole(ADMIN_ROLE) {
        MetaNode = _MetaNode;

        emit SetMetaNode(_MetaNode);
    }

    // 暂停提现功能
    function pauseWithdraw() public onlyRole(ADMIN_ROLE) {
        require(!withdrawPaused, "withdraw has been already paused");

        withdrawPaused = true;

        emit PauseWithdraw();
    }

    // 取消暂停提现功能
    function unpauseWithdraw() public onlyRole(ADMIN_ROLE) {
        require(withdrawPaused, "withdraw is not paused");

        withdrawPaused = false;
        
        emit UnpauseWithdraw();
    }

    // 暂停领取功能
    function pauseClaim() public onlyRole(ADMIN_ROLE) {
        require(!claimPaused, "claim has been already paused");

        claimPaused = true;

        emit PauseClaim();
    }

    // 取消暂停领取功能
    function unpauseClaim() public onlyRole(ADMIN_ROLE) {
        require(claimPaused, "claim is not paused");

        claimPaused = false;

        emit UnpauseClaim();
    }

    // 设置质押开始区块高度
    function setStartBlock(uint256 _startBlock) public onlyRole(ADMIN_ROLE) {
        require(_startBlock <= endBlock, "start block must be smaller than end block");

        startBlock = _startBlock;

        emit SetStartBlock(_startBlock);
    }

    // 设置质押结束区块高度
    function setEndBlock(uint256 _endBlock) public onlyRole(ADMIN_ROLE) {
        require(_endBlock >= startBlock, "end block must be greater than start block");

        endBlock = _endBlock;

        emit SetEndBlock(_endBlock);
    }

    // 设置每个区块高度 MetaNode 奖励数量
    function setMetaNodePerBlock(
        uint256 _MetaNodePerBlock
    ) public onlyRole(ADMIN_ROLE) {
        require(_MetaNodePerBlock > 0, "MetaNode per block must be greater than zero");

        MetaNodePerBlock = _MetaNodePerBlock;

        emit SetMetaNodePerBlock(_MetaNodePerBlock);
    }

    // 添加资金池
    function addPool(
        address _stTokenAddress,
        uint256 _poolWeight,
        uint256 _minDepositAmount,
        uint256 _unstakeLockBlocks,
        bool _withUpdate
    ) public onlyRole(ADMIN_ROLE) {
        
        if (pool.length > 0) {
            require(
                _stTokenAddress != address(0x0),
                "staking token address cannot be zero address"
            );
        } else {
            require(
                _stTokenAddress == address(0x0),
                "the first pool must be ETH pool"
            );
        }

        // allow the min deposit amount equal to 0
        require(_unstakeLockBlocks > 0, "invalid unstake lock blocks");
        require(block.number < endBlock, "Already ended");

        // 更新所有资金池
        if(_withUpdate) {
            massUpdatePools();
        }

        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalPoolWeight += _poolWeight;

        pool.push(
            Pool({
                stTokenAddress: _stTokenAddress,
                poolWeight: _poolWeight,
                lastRewardBlock: lastRewardBlock,
                accMetaNodePerST: 0,
                stTokenAmount: 0,
                minDepositAmount: _minDepositAmount,
                withdrawLockBlocks: _unstakeLockBlocks
            })
        );

        emit AddPool (
            _stTokenAddress,
            _poolWeight,
            lastRewardBlock,
            _minDepositAmount,
            _unstakeLockBlocks
        );
    }


    function updatePool(
        uint256 _pid, 
        uint256 _minDepositAmount, 
        uint256 _unstakeLockBlocks
    ) public onlyRole(ADMIN_ROLE) checkPid(_pid) {
        
        pool[_pid].minDepositAmount = _minDepositAmount;
        pool[_pid].unstakeLockedBlocks = _unstakeLockBlocks;

        emit UpdatePoolInfo(_pid, _minDepositAmount, _unstakeLockBlocks);
    }


    function setPoolWeight(
        uint256 _pid, 
        uint256 _poolWeight,
        bool _withUpdate
    ) public onlyRole(ADMIN_ROLE) checkPid(_pid) {
        require(_poolWeight > 0, "invalid pool weight");

        if(_withUpdate) {
            massUpdatePools();
        }

        totalPoolWeight = totalPoolWeight - pool[_pid].poolWeight + _poolWeight;
        pool[_pid].poolWeight = _poolWeight;

        emit SetPoolWeight(_pid, _poolWeight, totalPoolWeight);
    }

    // ================ Query FUNCTIONS：查询函数的定义 ================
    


}
