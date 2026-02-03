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
        UnstakeRequest[] requests;
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

    // 用户请求取消质押代币事件
    event RequestUnstake (
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
        uint256 _unstakeLockedBlocks,
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
        // require资金池权重大于0
        require(_unstakeLockedBlocks > 0, "invalid unstake lock blocks");
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
                unstakeLockedBlocks: _unstakeLockedBlocks
            })
        );

        emit AddPool (
            _stTokenAddress,
            _poolWeight,
            lastRewardBlock,
            _minDepositAmount,
            _unstakeLockedBlocks
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

    // 获取资金池数量
    function poolLength() external view returns (uint256) {
        return pool.length;
    }

    // Return reward multiplier over given _from to _to block. [_from, _to)
    // 计算从 _from 区块到 _to 区块的奖励倍数
    function getMultiplier(
        uint256 _from, 
        uint256 _to
    ) public view returns (uint256 multiplier) {
        // _from 必须小于等于 _to
        require(_from <= _to, "invalid block");

        // 如果 _from 小于质押开始区块高度，则将 _from 设置为质押开始区块高度
        if(_from < startBlock) {
            _from = startBlock;
        }
        // 如果 _to 大于质押结束区块高度，则将 _to 设置为质押结束区块高度
        if(_to > endBlock) {
            _to = endBlock;
        }
        // 确保调整后的 _from 仍然小于等于 _to
        require(_from <= _to, "end block must be greater than start block");
        bool success;
        // 计算奖励倍数
        (success, multiplier) = (_to - _from).tryMul(MetaNodePerBlock);
        // 判断是否溢出
        require(success, "multiplier overflow");
    }

    function pendingMetaNode (
        uint256 _pid, 
        address _user
    ) external view checkPid(_pid) returns(uint256) {
        return pendingMetaNodeByBlockNumber(_pid, _user, block.number);
    }

    // Get pending MetaNode amount of user by block number in pool
    // 根据区块高度，获取用户在资金池中待领取的 MetaNode 数量
    function pendingMetaNodeByBlockNumber (
        uint256 _pid,
        address _user,
        uint256 _blockNumber
    ) public view checkPid(_pid) returns (uint256) {
        Pool storage pool_ = pool[_pid];
        User storage user_ = user[_pid][_user];
        uint256 accMetaNodePerST = pool_.accMetaNodePerST;
        uint256 stSupply = pool_.stTokenAmount;

        if(_blockNumber > pool_.lastRewardBlock && stSupply != 0) {
            uint256 multiplier = getMultiplier(
                pool_.lastRewardBlock,
                _blockNumber
            );
            uint256 MetaNodeForPool = (multiplier * pool_.poolWeight) / totalPoolWeight;
            accMetaNodePerST += (MetaNodeForPool * (1 ether)) / stSupply;
        }
        return (user_.stAmount * accMetaNodePerST) / (1 ether) - user_.finishedMetaNode + user_.pendingMetaNode;
    }

    // Get staking balance of user in pool
    // 获取用户在资金池中的质押余额
    function stakingBalance(
        uint256 _pid,
        address _user
    ) external view checkPid(_pid) returns (uint256) {
        return user[_pid][_user].stAmount;
    }

    // Get the withdraw amount info, including the locked unstake amount and the unlocked unstake amount
    // 获取用户取消质押的金额信息，包括锁定的取消质押金额和解锁的取消质押金额
    function withdrawAmount(uint256 _pid, address _user) public view checkPid(_pid) returns (uint256 requestAmount, uint256 pendingWithdrawAmount) {
        User storage user_ = user[_pid][_user];

        for(uint256 i = 0; i < user_.requests.length; i++) {
            if(user_.requests[i].unblockBlocks <= block.number) {
                pendingWithdrawAmount += user_.requests[i].amount;
            } else {
                requestAmount += user_.requests[i].amount;
            }
        }
    }


    // ================ PUBLIC FUNCTIONS：公共函数的定义 ================

    // Update reward variables of the given pool to be up-to-date.
    // 更新给定资金池的奖励变量，使其保持最新状态
    function updatePool(uint256 _pid) public checkPid(_pid) {
        Pool storage pool_ = pool[_pid];

        // 如果当前区块高度小于等于上次奖励区块高度，则直接返回
        if(block.number <= pool_.lastRewardBlock) {
            return;
        }

        // 如果质押代币数量为0或资金池权重为0，则更新上次奖励区块高度为当前区块高度并返回
        (bool success1, uint256 totalMetaNode) = getMultiplier(
            pool_.lastRewardBlock, 
            block.number
        ).tryMul(pool_.poolWeight);
        require(success1, "totalMetaNode overflow");

        // 计算总的 MetaNode 奖励
        (success1, totalMetaNode) = totalMetaNode.tryDiv(totalPoolWeight);
        require(success1, "totalMetaNode div overflow");

        // 如果质押代币数量大于0，则更新每个质押代币的累计 MetaNode 奖励
        uint256 stSupply = pool_.stTokenAmount;
        if (stSupply > 0) {
            
            // 计算总的 MetaNode 奖励乘以 1 ether，防止精度丢失
            (bool success2, uint256 totalMetaNode_) = totalMetaNode.tryMul(1 ether);
            require(success2, "totalMetaNode_ overflow");

            // 计算 totalMetaNode_ 除以 stSupply
            (success2, totalMetaNode_) = totalMetaNode_.tryDiv(stSupply);
            require(success2, "totalMetaNode_ div overflow");
            
            (bool success3, uint256 accMetaNodePerST) = pool_.accMetaNodePerST.tryAdd(totalMetaNode_);
            require(success3, "accMetaNodePerST overflow");

            pool_.accMetaNodePerST = accMetaNodePerST;
        }

        // 更新上次奖励区块高度为当前区块高度
        pool_.lastRewardBlock = block.number;

        emit UpdatePool(_pid, pool_.lastRewardBlock, totalMetaNode);
    }


    // Update reward variables for all pools. Be careful of gas spending!
    // 更新所有资金池的奖励变量。注意燃气消耗！
    function massUpdatePools() public {
        uint256 length = pool.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Deposit staking ETH for MetaNode rewards
    // 存入质押 ETH 以获取 MetaNode 奖励
    function depositETH() public payable whenNotPaused {
        Pool storage pool_ = pool[ETH_PID];
        require(
            pool_.stTokenAddress == address(0x0),
            "invalid staking token address"
        );

        uint256 _amount = msg.value;

        require(
            _amount >= pool_.minDepositAmount,
            "deposit amount is too small"
        );

        _deposit(ETH_PID, _amount);
    }

    // Deposit staking token for MetaNode rewards
    // Before depositing, user needs approve this contract to be able to spend or transfer their staking tokens
    // 存入质押代币以获取 MetaNode 奖励
    // 在存入之前，用户需要批准此合约能够花费或转移他们的质押代币
    function deposit(
        uint256 _pid,
        uint256 _amount
    ) public whenNotPaused checkPid(_pid) {
        require(_pid != 0, "deposit not support ETH staking");

        Pool storage pool_ = pool[_pid];
        require(
            _amount > pool_.minDepositAmount,
            "deposit amount is too small"
        );

        if(_amount > 0) {
            IERC20(pool_.stTokenAddress).safeTransferFrom(
                msg.sender,
                address(this),
                _amount
            );
        }
        _deposit(_pid, _amount);
    }


    // Unstake staking tokens
    // _pid: Id of the pool to be withdrawn from
    // _amount: amount of staking tokens to be withdrawn
    // 取消质押代币
    function unstake(
        uint256 _pid,
        uint256 _amount
    ) public whenNotPaused checkPid(_pid) whenNotWithdrawPaused {
        Pool storage pool_ = pool[_pid];
        User storage user_ = user[_pid][msg.sender];

        require(user_.stAmount >= _amount, "Not enough staking token balance");

        // 为啥这里传参不完整呢？只传了一个_pid呢？
        // --- IGNORE ---
        // 回答我：因为这里只是更新指定资金池的奖励变量，不需要传入用户地址
        // 那updatePool 函数中的其他参数不传就会有什么影响吗？
        // 回答我：不会有影响，因为updatePool函数只需要资金池ID来更新该资金池的奖励变量
        // _minDepositAmount， _unstakeLockBlocks 这些参数是用来更新资金池信息的，不是用来更新奖励变量的 
        // 那他两会怎么样呢？
        // 回答我：他两会保持不变，因为这里没有调用更新资金池信息的函数
        updatePool(_pid);

        uint256 pendingMetaNode_ = (user_.stAmount * pool_.accMetaNodePerST) / (1 ether) - user_.finishedMetaNode;

        if(pendingMetaNode_ > 0) {
            user_.pendingMetaNode += pendingMetaNode_;
        }

        if(_amount > 0) {
            user_.stAmount = user_.stAmount - _amount;
            user_.requests.push(
                UnstakeRequest({
                    amount: _amount,
                    unblockBlocks: block.number + pool_.unstakeLockedBlocks
                })
            );
        }

        pool_.stTokenAmount = pool_.stTokenAmount - _amount;
        user_.finishedMetaNode = (user_.stAmount * pool_.accMetaNodePerST) / (1 ether);

        emit RequestUnstake(msg.sender, _pid, _amount);
    }


    function withdraw( uint256 _pid) public whenNotPaused checkPid(_pid) whenNotWithdrawPaused {
        Pool storage pool_ = pool[_pid];
        User storage user_ = user[_pid][msg.sender];

        uint256 pendingWithdraw_;
        uint256 popNum_;

        for(uint256 i = 0; i < user_.requests.length; i++) {
            if(user_.requests[i].unblockBlocks <= block.number) {
                break;
            }
            pendingWithdraw_ += user_.requests[i].amount;
            popNum_++;
        }

        for(uint256 i = 0; i < user_.requests.length - popNum_; i++) {
            user_.requests[i] = user_.requests[i + popNum_];
        }

        for(uint256 i = 0; i< popNum_; i++) {
            user_.requests.pop();
        }

        if(pendingWithdraw_ > 0) {
            if(pool_.stTokenAddress == address(0x0)) {
                _safeETHTransfer(msg.sender, pendingWithdraw_);
            } else {
                IERC20(pool_.stTokenAddress).safeTransfer(msg.sender, pendingWithdraw_);
            }
        }
        emit Withdraw(msg.sender, _pid, pendingWithdraw_, block.number);
    }


    // Claim MetaNode tokens reward
    // 领取 MetaNode 代币奖励
    function claim(uint256 _pid) public whenNotPaused checkPid(_pid) whenNotClaimPaused {
        Pool storage pool_ = pool[_pid];
        User storage user_ = user[_pid][msg.sender];

        updatePool(_pid);

        uint256 pendingMetaNode_ = (user_.stAmount * pool_.accMetaNodePerST) / (1 ether) - user_.finishedMetaNode + user_.pendingMetaNode;

        if(pendingMetaNode_ > 0) {
            user_.pendingMetaNode = 0;
            _safeMetaNodeTransfer(msg.sender, pendingMetaNode_);
        }

        user_.finishedMetaNode = (user_.stAmount * pool_.accMetaNodePerST) / (1 ether);

        emit Claim(msg.sender, _pid, pendingMetaNode_);
    }


    // ================= INTERNAL FUNCTIONS：内部函数的定义 ================


    // Internal deposit function\
    // 内部存款函数
    function _deposit(uint256 _pid,uint256 _amount) internal {
        Pool storage pool_ = pool[_pid];
        User storage user_ = user[_pid][msg.sender];

        updatePool(_pid);

        if(user_.stAmount > 0) {
            // uint256 accST = user_.stAmount * pool_.accMetaNodePerST / (1 ether);
            (bool success1, uint256 accST) = user_.stAmount.tryMul(pool_.accMetaNodePerST);
            require(success1, "user stAmount mul accMetaNodePerST overflow");

            (success1, accST) = accST.tryDiv(1 ether);
            require(success1, "accST div 1 ether overflow");

            (bool success2, uint256 pendingMetaNode_) = accST.trySub(user_.finishedMetaNode);
            require(success2, "accST sub finishedMetaNode overflow");

            if(pendingMetaNode_ > 0) {
                (bool success3, uint256 _pendingMetaNode) = user_.pendingMetaNode.tryAdd(pendingMetaNode_);
                require(success3, "user pendingMetaNode overflow");
                user_.pendingMetaNode = _pendingMetaNode;
            }
        }

        if(_amount > 0) {
            (bool success4, uint256 stAmount) = user_.stAmount.tryAdd(_amount);
            require(success4, "user stAmount overflow");
            user_.stAmount = stAmount;
        }

        (bool success5, uint256 stTokenAmount) = pool_.stTokenAmount.tryAdd(_amount);
        require(success5, "pool stTokenAmount overflow");
        pool_.stTokenAmount = stTokenAmount;

        (bool success6, uint256 finishedMetaNode) = user_.stAmount.tryMul(pool_.accMetaNodePerST);
        require(success6, "user stAmount mul accMetaNodePerST overflow");

        (success6, finishedMetaNode) = finishedMetaNode.tryDiv(1 ether);
        require(success6, "finishedMetaNode div 1 ether overflow");

        user_.finishedMetaNode = finishedMetaNode;

        emit Deposit(msg.sender, _pid, _amount);
    }

    // Safe MetaNode transfer function, just in case if rounding error causes pool to not have enough MetaNodes.
    // 安全的 MetaNode 转账函数，以防止由于舍入误差导致资金池没有足够的 MetaNode
    function _safeMetaNodeTransfer(address _to, uint256 _amount) internal {
        uint256 MetaNodeBal = MetaNode.balanceOf(address(this));

        if(_amount > MetaNodeBal) {
            MetaNode.transfer(_to, MetaNodeBal);
        } else {
            MetaNode.transfer(_to, _amount);
        }
    }

    // Safe ETH transfer function, just in case if rounding error causes pool to not have enough ETH.
    // 安全的 ETH 转账函数，以防止由于舍入误差导致资金池没有足够的 ETH
    function _safeETHTransfer(address _to, uint256 _amount) internal {

        (bool success, bytes memory data) = address(_to).call{value: _amount}("");

        require(success, "ETH transfer call failed");

        if (data.length > 0) {
            require(abi.decode(data, (bool)), "ETH transfer operation did not succeed");
        }
    }


}
