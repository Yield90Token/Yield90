// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// OpenZeppelin
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

interface IY90NFT {
    function burnFromCirculating(uint256 amount, address burner, uint256 tokenId) external;
    function verifyBurnCompletion(address burner, uint256 amount) external returns (bool);
}

interface IUniswapV2Router02 {
    function WETH() external view returns (address);
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
}

contract Yield90 is ERC20, ERC20Permit, ERC20Burnable, Ownable, ReentrancyGuard {
    uint256 public constant APY = 90;
    uint256 public constant TOTAL_SUPPLY = 10_000_000_000 * 10**18;
    uint256 public constant REWARDS_POOL = 7_000_000_000 * 10**18;
    uint256 public constant PROJECT_FUND = 1_000_000_000 * 10**18;
    uint256 public constant DEX_CEX_LISTING = 2_000_000_000 * 10**18;
    uint256 public constant INITIAL_LP_ALLOC = 800_000_000 * 10**18;
    uint256 public constant CEX_RESERVE_ALLOC = 1_200_000_000 * 10**18;
    uint256 public constant CIRCULATING_BURN_LIMIT = (DEX_CEX_LISTING * 50) / 100;
    uint256 public constant LOCK_PERIOD = 14 days;
    uint256 public constant ANTI_FLASH_LOAN_LOCK = 30 minutes;
    uint256 public constant MIN_CLAIM_AMOUNT = 1 * 10**18;
    uint256 public constant MIN_CLAIM_INTERVAL = 3 days;
    uint256 public constant VOTE_THRESHOLD = 15;
    uint256 public initialLpRemaining;
    uint256 public cexReserveRemaining;
    uint256 public rewardsDistributed;
    struct PoolInfo {
        IERC20 stakingToken;       
        uint256 accRewardPerShare;
        uint64 lastRewardUpdate;
        uint256 totalStaked;
    }
    PoolInfo[] public poolInfo;
    mapping(address => uint256) internal _tokenToPidPlusOne;

    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
        uint64 lastStakeTime;
        uint64 lastClaimTime;
    }
    mapping(uint256 => mapping(address => UserInfo)) public userInfo; 
    uint256 public totalY90Staked;
    IY90NFT public y90NFT;
    mapping(address => uint256) public lastBurnTime;
    struct BurnRecord { uint128 totalBurnt; uint64 lastBurnTime; uint32 burnCount; }
    mapping(address => BurnRecord) public burnRecords;
    uint256 public totalBurntFromCirculating;
    mapping(uint256 => uint256) public nftVoteWeight;
    uint256 public totalGovernanceVotes;
    uint256 internal constant PRECISION_FACTOR = 1e18;
    uint256 public penaltiesCollected;
    uint256 public immutable deploymentTime;
    IUniswapV2Router02 public router;
    address public weth;
    uint256 public constant MAX_BATCH = 200;
    event PoolAdded(uint256 indexed pid, address stakingToken);
    event Staked(address indexed user, uint256 indexed pid, uint256 amount, uint256 unlockTime);
    event Unstaked(address indexed user, uint256 indexed pid, uint256 amount, uint256 reward);
    event EarlyUnstake(address indexed user, uint256 indexed pid, uint256 amount, uint256 reward, uint256 penalty);
    event RewardsClaimed(address indexed user, uint256 indexed pid, uint256 amount);
    event TokensBurnt(address indexed nftHolder, uint256 amount, uint256 tokenId);
    event Y90NFTSet(address indexed nftContract);
    event TokensRescued(address indexed token, address to, uint256 amount);
    event NativeRescued(address indexed to, uint256 amount);
    event RewardsBurnt(uint256 amount);
    event DistributedRewards(uint256 totalAmount, address[] recipients);
    event RouterSet(address router, address weth);
    event PenaltyCollected(address indexed user, uint256 penalty, uint256 totalPenalties);

    constructor(address multisig) ERC20("Yield90", "Y90") ERC20Permit("Yield90") {
        require(multisig != address(0), "Invalid multisig");
        _transferOwnership(multisig);
        initialLpRemaining = INITIAL_LP_ALLOC;
        cexReserveRemaining = CEX_RESERVE_ALLOC;
        _mint(address(this), REWARDS_POOL + initialLpRemaining);
        _mint(multisig, PROJECT_FUND + cexReserveRemaining);
        uint256 minted = REWARDS_POOL + initialLpRemaining + PROJECT_FUND + cexReserveRemaining;
        require(minted == TOTAL_SUPPLY, "Minting mismatch");
        deploymentTime = block.timestamp;
        _addPool(address(this));
        poolInfo[0].lastRewardUpdate = uint64(block.timestamp);
    }
    function balanceOf(address account) public view override returns (uint256) {
        return super.balanceOf(account);
    }
    function allowance(address owner, address spender) public view override returns (uint256) {
        return super.allowance(owner, spender);
    }
    function approve(address spender, uint256 amount) public override returns (bool) {
        require(spender != address(0), "Approve to zero address");
        super.approve(spender, amount);
        return true;
    }
    function transfer(address recipient, uint256 amount) public override returns (bool) {
         return super.transfer(recipient, amount);
    }
    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        return super.transferFrom(sender, recipient, amount);
    }
    function circulatingSupply() public view returns (uint256) {
        return totalSupply() - balanceOf(address(this)) - balanceOf(owner());
    }
 
    function _addPool(address stakingToken) internal returns (uint256 pid) {
        require(stakingToken != address(0), "Zero token");
        require(_tokenToPidPlusOne[stakingToken] == 0, "Pool exists");
        PoolInfo memory p = PoolInfo({
            stakingToken: IERC20(stakingToken),
            accRewardPerShare: 0,
            lastRewardUpdate: uint64(block.timestamp),
            totalStaked: 0
        });
        poolInfo.push(p);
        pid = poolInfo.length - 1;
        _tokenToPidPlusOne[stakingToken] = pid + 1;
        emit PoolAdded(pid, stakingToken);
    }

    function addPool(address stakingToken) external onlyOwner returns (uint256) {
        return _addPool(stakingToken);
    }

    function pidForToken(address token) public view returns (uint256) {
        uint256 v = _tokenToPidPlusOne[token];
        require(v != 0, "Pool not found");
        return v - 1;
    }
 
    function setRouter(address _router) external onlyOwner {
        require(_router != address(0), "Invalid router");
        router = IUniswapV2Router02(_router);
        weth = router.WETH();
        _approve(address(this), address(router), type(uint256).max);
        emit RouterSet(_router, weth);
    }
 
    function updatePool(uint256 pid) internal returns (uint256) {
        PoolInfo storage pool = poolInfo[pid];
        if (block.timestamp <= pool.lastRewardUpdate) return pool.accRewardPerShare;
        uint256 stakedSupply = pool.totalStaked;
        if (stakedSupply == 0) {
            pool.lastRewardUpdate = uint64(block.timestamp);
            return pool.accRewardPerShare;
        }

        uint256 timeElapsed = block.timestamp - pool.lastRewardUpdate;
        uint256 rewards = (stakedSupply * APY * timeElapsed) / (365 days * 100);

        uint256 remainingRewards = REWARDS_POOL - rewardsDistributed;
        if (rewards > remainingRewards) {
            rewards = remainingRewards;
        }

        if (rewards > 0) {
            pool.accRewardPerShare += (rewards * PRECISION_FACTOR) / stakedSupply;
        }
        pool.lastRewardUpdate = uint64(block.timestamp);
        return pool.accRewardPerShare;
    }

    function pendingRewards(uint256 pid, address user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage u = userInfo[pid][user];
        uint256 acc = pool.accRewardPerShare;
        if (block.timestamp > pool.lastRewardUpdate && pool.totalStaked > 0) {
            uint256 timeElapsed = block.timestamp - pool.lastRewardUpdate;
            uint256 rewards = (pool.totalStaked * APY * timeElapsed) / (365 days * 100);
            uint256 remainingRewards = REWARDS_POOL - rewardsDistributed;
            if (rewards > remainingRewards) rewards = remainingRewards;
            acc += (rewards * PRECISION_FACTOR) / pool.totalStaked;
        }
        uint256 pending = (u.amount * acc) / PRECISION_FACTOR;
        if (pending <= u.rewardDebt) return 0;
        return pending - u.rewardDebt;
    }
 
    function stake(uint256 amount) external nonReentrant {
        _stakePid(0, amount, msg.sender);
    }

    function stakeFor(uint256 pid, uint256 amount) external nonReentrant {
        _stakePid(pid, amount, msg.sender);
    }
 
    function _stakePid(uint256 pid, uint256 amount, address user) internal {
        require(amount > 0, "Zero amount");
        require(pid < poolInfo.length, "Invalid pool");
        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage u = userInfo[pid][user];
        if (address(pool.stakingToken) == address(this)) {
            require(amount <= getStakeLimit(), "Stake limit reached");
            require(block.timestamp >= u.lastStakeTime + ANTI_FLASH_LOAN_LOCK, "Cooldown active");
        }
        uint256 acc = updatePool(pid);
        if (u.amount > 0) {
            uint256 pending = (u.amount * acc) / PRECISION_FACTOR;
            if (pending > u.rewardDebt) {
                uint256 pay = pending - u.rewardDebt;
                if (pay > 0) safeRewardTransfer(user, pay);
            }
        }
        require(pool.stakingToken.transferFrom(user, address(this), amount), "transferFrom failed");
        u.amount += amount;
        pool.totalStaked += amount;
        if (address(pool.stakingToken) == address(this)) {
            totalY90Staked += amount;
        }
        u.rewardDebt = (u.amount * pool.accRewardPerShare) / PRECISION_FACTOR;
        u.lastStakeTime = uint64(block.timestamp);
        u.lastClaimTime = uint64(block.timestamp);
        emit Staked(user, pid, amount, block.timestamp + LOCK_PERIOD);
    }

    function stakeWithPermitPid(uint256 pid, uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s ) external nonReentrant {
        require(pid < poolInfo.length, "Invalid pid");
        PoolInfo storage pool = poolInfo[pid];
        address tokenAddr = address(pool.stakingToken);
        require(tokenAddr != address(0), "Zero token");
        IERC20Permit(tokenAddr).permit(msg.sender, address(this), amount, deadline, v, r, s);
        _stakePid(pid, amount, msg.sender);
    }

    function stakeLP(uint256 pid, uint256 amount) external nonReentrant {
        _stakePid(pid, amount, msg.sender);
    }

    function stakeWithETH( uint256 pid, uint256 amountOutMin, uint256 amountTokenMin, uint256 amountETHMin,  uint256 deadline) external payable nonReentrant {
        require(msg.value > 0, "No ETH sent");
        require(pid < poolInfo.length, "Invalid pool");
        PoolInfo storage pool = poolInfo[pid];
        require(address(pool.stakingToken) != address(this), "stakeWithETH is for LP pools only");
        require(address(router) != address(0) && weth != address(0), "Router not configured");
        uint256 ethAmountTotal = msg.value;
        uint256 ethToSwap = ethAmountTotal / 2;
        uint256 ethForLiquidity = ethAmountTotal - ethToSwap;
        uint256 y90Before = balanceOf(address(this));
        address[] memory path = new address[](2);
        path[0] = weth;
        path[1] = address(this);
        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: ethToSwap}(amountOutMin, path, address(this), deadline);
        uint256 y90After = balanceOf(address(this));
        uint256 tokensReceived = y90After - y90Before;
        require(tokensReceived > 0, "Swap failed or returned zero tokens");
        (uint256 amountTokenUsed, uint256 amountETHUsed, uint256 liquidity) =
            router.addLiquidityETH{value: ethForLiquidity}(address(this), tokensReceived, amountTokenMin, amountETHMin, address(this), deadline);
        require(liquidity > 0, "Liquidity failed");
        _creditStakeLPForUser(pid, msg.sender, liquidity);
        if (tokensReceived > amountTokenUsed) {
            uint256 leftover = tokensReceived - amountTokenUsed;
            _transfer(address(this), msg.sender, leftover);
        }
        if (ethForLiquidity > amountETHUsed) {
            uint256 leftoverEth = ethForLiquidity - amountETHUsed;
            (bool sent,) = payable(msg.sender).call{value: leftoverEth}("");
            require(sent, "ETH refund failed");
        }
    }

    function _creditStakeLPForUser(uint256 pid, address user, uint256 liquidity) internal {
        require(pid < poolInfo.length, "Invalid pid");
        PoolInfo storage pool = poolInfo[pid];
        require(liquidity > 0, "Zero liquidity");
        uint256 acc = updatePool(pid);
        UserInfo storage u = userInfo[pid][user];
        if (u.amount > 0) {
            uint256 pending = (u.amount * acc) / PRECISION_FACTOR;
            if (pending > u.rewardDebt) {
                uint256 pay = pending - u.rewardDebt;
                if (pay > 0) safeRewardTransfer(user, pay);
            }
        }
        u.amount += liquidity;
        pool.totalStaked += liquidity;
        u.rewardDebt = (u.amount * pool.accRewardPerShare) / PRECISION_FACTOR;
        u.lastStakeTime = uint64(block.timestamp);
        u.lastClaimTime = uint64(block.timestamp);
        emit Staked(user, pid, liquidity, block.timestamp + LOCK_PERIOD);
    }

    function unstake() external nonReentrant {
        _unstakePid(0, msg.sender);
    }

    function unstakePid(uint256 pid) external nonReentrant {
        _unstakePid(pid, msg.sender);
    }

    function _unstakePid(uint256 pid, address user) internal {
        require(pid < poolInfo.length, "Invalid pid");
        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage u = userInfo[pid][user];
        require(u.amount > 0, "No stake to unstake");
        require(block.timestamp >= u.lastStakeTime + LOCK_PERIOD, "Funds locked");
        uint256 acc = updatePool(pid);
        uint256 rewardDebtCalc = (u.amount * acc) / PRECISION_FACTOR;
        uint256 pendingRwds = 0;
        if (rewardDebtCalc > u.rewardDebt) {
            pendingRwds = rewardDebtCalc - u.rewardDebt;
        } else {
            pendingRwds = 0;
        }
        if (pendingRwds > 0) {
            pendingRwds = Math.min(pendingRwds, REWARDS_POOL - rewardsDistributed);
            rewardsDistributed += pendingRwds;
            _transfer(address(this), user, pendingRwds);
        }

        pool.totalStaked -= u.amount;
        if (address(pool.stakingToken) == address(this)) {
            if (totalY90Staked >= u.amount) totalY90Staked -= u.amount;
            else totalY90Staked = 0;
        }
        require(pool.stakingToken.transfer(user, u.amount), "Principal transfer failed");
        emit Unstaked(user, pid, u.amount, pendingRwds);
        delete userInfo[pid][user];
    }

    function earlyUnstake() external nonReentrant {
        _earlyUnstakePid(0, msg.sender);
    }

    function earlyUnstakePid(uint256 pid) external nonReentrant {
        _earlyUnstakePid(pid, msg.sender);
    }

    function _earlyUnstakePid(uint256 pid, address user) internal {
        require(pid < poolInfo.length, "Invalid pid");
        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage u = userInfo[pid][user];
        require(u.amount > 0, "No stake");
        uint256 acc = updatePool(pid);
        uint256 penalty = u.amount / 4;
        uint256 remainingPrincipal = u.amount - penalty;
        uint256 accumulated = (u.amount * acc) / PRECISION_FACTOR;
        uint256 pendingRewardsLocal = 0;
        if (accumulated >= u.rewardDebt) pendingRewardsLocal = accumulated - u.rewardDebt;
        else pendingRewardsLocal = 0;
        uint256 penalizedRewards = pendingRewardsLocal / 2; 
        if (pool.totalStaked >= u.amount) pool.totalStaked -= u.amount;
        else pool.totalStaked = 0;
        if (address(pool.stakingToken) == address(this)) {
            if (totalY90Staked >= u.amount) totalY90Staked -= u.amount;
            else totalY90Staked = 0;
        }
        if (penalizedRewards > 0) {
            rewardsDistributed += penalizedRewards;
            _transfer(address(this), user, penalizedRewards);
        }
        penaltiesCollected += penalty;
        emit PenaltyCollected(user, penalty, penaltiesCollected);
        require(pool.stakingToken.transfer(user, remainingPrincipal), "Principal transfer failed");
        delete userInfo[pid][user];
        emit EarlyUnstake(user, pid, remainingPrincipal, penalizedRewards, penalty);
    }

    function claimRewards() external nonReentrant {
        _claimPid(0, msg.sender);
    }

    function claimRewardsPid(uint256 pid) external nonReentrant {
        _claimPid(pid, msg.sender);
    }

    function _claimPid(uint256 pid, address user) internal {
        require(pid < poolInfo.length, "Invalid pid");
        UserInfo storage u = userInfo[pid][user];
        require(u.amount > 0, "No stake");
        uint256 acc = updatePool(pid);
        uint256 pending = 0;
        uint256 accumulated = (u.amount * acc) / PRECISION_FACTOR;
        if (accumulated > u.rewardDebt) pending = accumulated - u.rewardDebt;
        else pending = 0;
        require(pending >= MIN_CLAIM_AMOUNT, "Reward too small");
        require(block.timestamp >= u.lastClaimTime + MIN_CLAIM_INTERVAL, "Wait 3 days");
        u.rewardDebt = (u.amount * acc) / PRECISION_FACTOR;
        u.lastClaimTime = uint64(block.timestamp);
        safeRewardTransfer(user, pending);
        emit RewardsClaimed(user, pid, pending);
    }

    function safeRewardTransfer(address to, uint256 amount) internal {
        uint256 rewardBudget = REWARDS_POOL - rewardsDistributed;
        if (amount > rewardBudget) amount = rewardBudget;
        uint256 contractBalance = balanceOf(address(this));
        uint256 locked = poolInfo.length > 0 ? poolInfo[0].totalStaked : 0;
        uint256 available = 0;
        if (contractBalance > locked) available = contractBalance - locked;
        require(available >= amount, "Insufficient reward reserves");
        _transfer(address(this), to, amount);
        rewardsDistributed += amount;
        require(rewardsDistributed <= REWARDS_POOL, "Rewards exceeded");
    }

    function getRemainingBurnCapacity() external view returns (uint256) {
        return CIRCULATING_BURN_LIMIT - totalBurntFromCirculating;
    }

    function burnFromCirculating(uint256 amount, address burner, uint256 tokenId) external nonReentrant {
        require(msg.sender == address(y90NFT), "Unauthorized");
        require(burner != address(0), "Invalid burner");
        require(block.timestamp >= lastBurnTime[burner] + LOCK_PERIOD, "2 weeks cool off");
        require(totalBurntFromCirculating + amount <= CIRCULATING_BURN_LIMIT, "Exceeds burn limit");
        uint256 burnAmount = amount;        
        uint256 contractBalanceBefore = balanceOf(address(this));
        require(contractBalanceBefore >= burnAmount, "Contract lacks tokens to burn");
        uint256 contractBalance = balanceOf(address(this));
        uint256 locked = poolInfo.length > 0 ? poolInfo[0].totalStaked : 0;
        uint256 rewardReserve = REWARDS_POOL - rewardsDistributed;
        uint256 available = contractBalance > (locked + rewardReserve) ? contractBalance - (locked + rewardReserve) : 0;
        require(available >= burnAmount, "Insufficient unallocated Y90 balance to burn");
        if (initialLpRemaining >= burnAmount) {
            initialLpRemaining -= burnAmount;
            _burn(address(this), burnAmount);
        } else {
            uint256 fromLP = initialLpRemaining;
            if (fromLP > 0) {
                initialLpRemaining = 0;
                _burn(address(this), fromLP);
            }
            uint256 remaining = burnAmount - fromLP;
            require(cexReserveRemaining >= remaining, "Not enough tokens left to burn");
            cexReserveRemaining -= remaining;
            _burn(address(this), remaining);
        }
        totalBurntFromCirculating += burnAmount;
        lastBurnTime[burner] = uint64(block.timestamp);
        y90NFT.verifyBurnCompletion(burner, burnAmount);
        emit TokensBurnt(burner, burnAmount, tokenId);
    }
 
    function setY90NFT(address _nftContract) external onlyOwner {
        require(_nftContract != address(0), "Invalid address");
        require(address(y90NFT) == address(0), "Y90NFT already set");
        y90NFT = IY90NFT(_nftContract);
        emit Y90NFTSet(_nftContract);
    }
 
    function registerGovernanceNFT(uint256 tokenId, uint256 voteWeight) external {
        require(msg.sender == address(y90NFT), "Unauthorized");
        require(nftVoteWeight[tokenId] == 0, "NFT already registered");
        nftVoteWeight[tokenId] = voteWeight;
        totalGovernanceVotes += voteWeight;
    }
 
    function distributeUnclaimedRewards(address[] calldata recipients, uint256[] calldata amounts, uint256[] calldata votingNFTs) external onlyOwner {
        require(block.timestamp > deploymentTime + 5 * 365 days, "Too early");
        require(recipients.length == amounts.length, "Array length mismatch");
        require(votingNFTs.length <= MAX_BATCH, "Too many voting NFTs");
        require(recipients.length <= MAX_BATCH, "Too many recipients");
        uint256 totalVotes = 0;
        for (uint i = 0; i < votingNFTs.length; i++) {
            totalVotes += nftVoteWeight[votingNFTs[i]];
        }
        require(totalVotes >= VOTE_THRESHOLD, "Insufficient votes (Need 15+)");
        uint256 remaining = REWARDS_POOL - rewardsDistributed;
        uint256 totalDistributed;
        uint256 len = recipients.length;
        for (uint256 i = 0; i < len; i++) {
            totalDistributed += amounts[i];
        }
        require(totalDistributed == remaining, "Incorrect total amount");
        for (uint256 i = 0; i < len; i++) {
            _transfer(address(this), recipients[i], amounts[i]);
        }
        rewardsDistributed = REWARDS_POOL;
        emit DistributedRewards(remaining, recipients);
    }

    function burnUnclaimedRewards(uint256[] calldata votingNFTs) external onlyOwner {
        require(block.timestamp > deploymentTime + 5 * 365 days, "Too early");
        require(votingNFTs.length <= MAX_BATCH, "Too many voting NFTs");

        uint256 totalVotes;
        for (uint i = 0; i < votingNFTs.length; i++) {
            totalVotes += nftVoteWeight[votingNFTs[i]];
        }
        require(totalVotes >= VOTE_THRESHOLD, "Insufficient votes (Need 15+)");

        uint256 remaining = REWARDS_POOL - rewardsDistributed;
        require(balanceOf(address(this)) >= remaining, "Insufficient balance");
 
        _burn(address(this), remaining);
        rewardsDistributed = REWARDS_POOL;
        emit RewardsBurnt(remaining);
    }
 
    function getRemainingRewards() public view returns (uint256) {
        return REWARDS_POOL - rewardsDistributed;
    }

    function getCirculatingBurnLimit() external pure returns (uint256) {
        return CIRCULATING_BURN_LIMIT;
    }

    function totalBurnt() external view returns (uint256) {
        return totalBurntFromCirculating;
    }

    function estimateRewardsForPid(address user, uint256 pid) external view returns (uint256) {
        return this.pendingRewards(pid, user);
    }

    function getStakeLimit() public view returns (uint256) {
        return totalSupply() / 100; 
    }
 
    function recoverERC20Tokens(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Invalid recipient");
        IERC20(token).transfer(to, amount);
        emit TokensRescued(token, to, amount);
    }

    function rescueNative(address payable to, uint256 amount) external onlyOwner {
        require(to != address(0), "Invalid recipient");
        to.transfer(amount);
        emit NativeRescued(to, amount);
    }
 
    receive() external payable {}
}