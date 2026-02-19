// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {SafeERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IKYCRegistry {
    function isFrozen(address user) external view returns (bool);
    function isKYCCompleted(address user) external view returns (bool);
}

/**
 * Fund (UUPS Upgradeable) — loop-free + import + live latch + provable claim solvency
 *
 * Core concept (final):
 * - Users BUY shares directly via buyShares() (trustless).
 * - FundIngress (owner/bridge) credits users via buySharesFor() (gated minter).
 * - Every inflow is split:
 *     reservePart -> investmentReserveWei (only investable bucket)
 *     distributablePart -> pro-rata credited to holders (always claimable)
 *
 * Solvency:
 * - claimObligationWei tracks total ETH owed to holders (claimable liability).
 * - invest() can ONLY spend from investmentReserveWei and must never starve claims.
 * - Invariant: address(this).balance >= claimObligationWei + investmentReserveWei
 *
 * Pricing:
 * - Piecewise-linear, non-decreasing bonding curve (volume-based).
 * - steps = totalVolume / stepWei
 * - price = basePrice + piecewise(steps)
 * - piecewise uses 2 breakpoints (k1, k2) and slopes (m1 >= m2 >= m3 >= 0)
 * - maxCurveSteps bounds steps to prevent “bricking” configs
 *
 * Upgrade posture:
 * - UUPS with one-way freezeUpgrades() latch.
 *
 * Notes:
 * - Redemption and reinvest are DISABLED (strict NO).
 * - Legacy exit/reinvest storage retained for upgrade compatibility but unused.
 */
contract Fund is
    UUPSUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    /* ───────── Constants ───────── */
    uint256 public constant PREC = 1e18;

    // Growth factor bounds (per step)
    uint256 public constant GROWTH_FACTOR_MIN = 5e15;   // 0.5%
    uint256 public constant GROWTH_FACTOR_MAX = 5e16;   // 5.0%

    // Default per-wallet lifetime volume cap (in wei); 0 = disabled
    uint256 public constant DEFAULT_WALLET_CAP = 100e18; // 100 ETH

    /* ───────── Bonding curve params ───────── */
    uint256 public basePrice;      // wei/share
    uint256 public growthFactor;   // 1e18-per-step
    uint256 public totalVolume;    // cumulative native in (wei) from buys + buyFor
    uint256 public lastPrice;      // last curve price

    // Explicit cap: steps must be <= this (prevents future price bricking)
    uint256 public maxCurveSteps;

    /* ───────── Shares ───────── */
    uint256 public totalShares; // 1e18-scaled
    mapping(address => uint256) public shareBalances;

    address[] private holders;
    mapping(address => bool) private isHolder;

    /* ───────── Rewards accounting ───────── */
    uint256 public accSalesPerShare; // 1e18 scale (from buys distributable)
    uint256 public accFeesPerShare;  // 1e18 scale (from revenue inflows, buffered fees)
    mapping(address => uint256) public rewardDebt;
    mapping(address => uint256) public pending;

    /* ───────── Fees buffer (receive + first-buy fallback) ───────── */
    uint256 public unallocatedFees;

    /* ───────── Legacy Exit reserve (DEPRECATED) ─────────
       Kept for storage-compatibility only. Do not use.
    */
    uint256 public exitReserveWei; // DEPRECATED
    uint16  public reserveBps;     // buy split bps -> reserve (now investmentReserveWei)
    uint16  public receiveReserveBps; // revenue split bps -> reserve (now investmentReserveWei)

    /* ───────── Legacy Exit model (DEPRECATED) ───────── */
    uint256 public exitFactor; // DEPRECATED
    mapping(address => uint256) public avgEntryPrice;        // DEPRECATED
    mapping(address => uint256) public lastPurchaseBlock;    // still useful as anti-grief/cooldown if you ever want it
    uint256 public redeemCooldown; // DEPRECATED
    bool public redemptionEnabled; // DEPRECATED (forced false)

    /* ───────── Caps / Guardian ───────── */
    uint256 public maxPurchaseShares; // per-tx shares cap (applies to buy/buyFor)
    address public guardian;

    /* ───────── buySharesFor gate ───────── */
    address public minter;
    bool public publicBuyForEnabled;

    /* ───────── View gating (optional) ───────── */
    mapping(address => bool) public allowedViewers;

    /* ───────── Upgrade latch ───────── */
    bool public upgradesFrozen;

    /* ───────── Importer state machine ───────── */
    bool public importsOpen;
    bool public importsFinalized;
    bool public live; // one-way "trading enabled" latch
    mapping(address => bool) public imported; // one-time import guard

    /* ───────── Regulatory controls ───────── */
    address public kycRegistry;                          // 0 = disabled
    mapping(address => bool) public isBlocked;           // blocked = no participation
    mapping(address => uint256) public lifetimeVolumeIn; // cumulative ETH in by wallet (buy/buyFor only)
    uint256 public walletCap;                            // per-wallet lifetime cap; 0 = disabled

    /* ───────── NEW: Solvency buckets (APPENDED) ───────── */
    uint256 public volumeStepWei;        // steps = totalVolume / volumeStepWei (e.g. 0.5 ETH)
    uint256 public claimObligationWei;   // total ETH owed to holders (always-claimable liability)
    uint256 public investmentReserveWei; // ONLY investable bucket (governance proposals)

    /* ───────── Events ───────── */
    event Purchase(address indexed buyer, uint256 nativeIn, uint256 sharesOut, uint256 price);
    event RewardsClaimed(address indexed user, uint256 amount);

    event SystemFeesBuffered(uint256 amount);
    event SystemFeesDistributed(uint256 amount, uint256 accFeesPerShare);

    event PriceParametersUpdated(uint256 basePrice, uint256 growthFactor);
    event VolumeStepUpdated(uint256 newStepWei);

    event MaxPurchaseUpdated(uint256 newMax);
    event GuardianUpdated(address indexed g);
    event MinterUpdated(address indexed minter);
    event PublicBuyForUpdated(bool enabled);

    event HoldersViewerAdded(address indexed viewer);
    event HoldersViewerRemoved(address indexed viewer);

    event ERC20Recovered(address indexed token, address indexed to, uint256 amount);

    event Imported(address indexed user, uint256 shares, uint256 pendingWei);
    event ImportsOpened();
    event ImportsFinalized();
    event LiveEnabled();

    event UserSnapshotEmitted(address indexed user, uint256 shares, uint256 pendingWei);

    event UpgradesFrozen();
    event MaxCurveStepsUpdated(uint256 newMaxSteps);

    // Regulatory events
    event KYCRegistryUpdated(address indexed registry);
    event WalletCapUpdated(uint256 newCap);
    event AddressBlocked(address indexed user, bool blocked);
    event LifetimeVolumeReset(address indexed user);

    // Reserve events (reserve == investmentReserveWei)
    event ReserveBpsUpdated(uint16 newBps);
    event ReceiveReserveBpsUpdated(uint16 newBps);
    event ReserveFunded(uint256 amountWei);
    event ReserveSpent(uint256 amountWei);
    event ReceiveRouted(uint256 toReserveWei, uint256 toDistributeWei);

    // Solvency events
    event ClaimObligationIncreased(uint256 amountWei, uint256 newTotal);
    event ClaimObligationDecreased(uint256 amountWei, uint256 newTotal);
    event Invested(address indexed to, uint256 amountWei, uint256 newReserveWei);

    // Accounting events
    event UnaccountedSwept(uint256 amountWei, bool toReserve);

    /* ───────── Custom errors ───────── */
    error Frozen();
    error BlockedNoParticipation();
    error StepsCap();
    error ShareBounds();
    error NoValue();
    error NoAuth();
    error ImportsClosed();
    error ImportsAlreadyFinalized();
    error AlreadyImported();
    error NotLive();
    error AlreadyLive();
    error BadGF();
    error BadBase();
    error BadBps();
    error Len();
    error NotSupported();
    error Solvency();

    /* ───────── Constructor: lock implementation ───────── */
    constructor() {
        _disableInitializers();
    }

    /* ───────── Initializer ───────── */
    function initialize(uint256 _basePrice, uint256 _growthFactor, address _initialOwner) public initializer {
        __UUPSUpgradeable_init();
        __Ownable_init(_initialOwner);
        __Pausable_init();
        __ReentrancyGuard_init();

        if (_basePrice == 0) revert BadBase();

        basePrice = _basePrice;
        growthFactor = _growthFactor; // legacy / deprecated for pricing
        lastPrice = _basePrice;

        // Strict NO redemption / reinvest (legacy flags forced off)
        redemptionEnabled = false;
        exitFactor = 0;
        redeemCooldown = 0;

        maxPurchaseShares = 100e18;
        walletCap = DEFAULT_WALLET_CAP;

        // Price hardening
        maxCurveSteps = 100_000;

        // Reserve policy defaults (tune as needed)
        // reserveBps = percent of buys routed to investmentReserveWei
        // receiveReserveBps = percent of non-buy revenues routed to investmentReserveWei
        reserveBps = 2000;        // 20% to reserve, 80% distributable
        receiveReserveBps = 2000; // 20% to reserve, 80% distributable

        // ─────────────────────────────────────────────────────────
        // NEW: Piecewise-linear pricing defaults (recommended)
        // steps = totalVolume / stepWei
        // price = basePrice + piecewise(steps)
        // ─────────────────────────────────────────────────────────

        // Smoothness: 0.1 ETH per step
        stepWei = 1e17;

        // Breakpoints (in steps)
        // k1 = 1000 steps => 100 ETH
        // k2 = 10000 steps => 1000 ETH
        k1 = 1000;
        k2 = 10_000;

        // Slopes (wei/share per step), monotone non-increasing to guarantee non-decreasing price:
        // Early phase (0..100 ETH): +20% over 100 ETH => +0.20 ETH over 1000 steps => 2e14 per step
        // Mid phase (100..1000 ETH): +0.90 ETH over 9000 steps => 1e14 per step
        // Late phase (>1000 ETH): +0.02 ETH per 100 ETH => +0.02 ETH over 1000 steps => 2e13 per step
        m1 = 200_000_000_000_000; // 2e14
        m2 = 100_000_000_000_000; // 1e14
        m3 = 20_000_000_000_000;  // 2e13

        // Keep old volumeStepWei around for ABI/storage if present, but it is deprecated by piecewise pricing.
        // If volumeStepWei is used elsewhere in your code, you may set it equal to stepWei for consistency.
        volumeStepWei = stepWei;

        // Import / live state
        importsOpen = false;
        importsFinalized = false;
        live = false;

        upgradesFrozen = false;

        emit PiecewiseParamsUpdated(stepWei, k1, k2, m1, m2, m3);
    }

    /* ───────── UUPS authorization with latch ───────── */
    function _authorizeUpgrade(address) internal view override onlyOwner {
        require(!upgradesFrozen, "upgrades frozen");
    }

    function freezeUpgrades() external onlyOwner {
        require(!upgradesFrozen, "already");
        upgradesFrozen = true;
        emit UpgradesFrozen();
    }

    /* ───────── Compliance policy ─────────
       - Frozen: deny ALL actions (buy/buyFor/claim)
       - Blocked: deny participation (claim still allowed)
    */
    modifier canParticipate(address user) {
        if (kycRegistry != address(0)) {
            if (IKYCRegistry(kycRegistry).isFrozen(user)) revert Frozen();
        }
        if (isBlocked[user]) revert BlockedNoParticipation();
        _;
    }

    modifier canExit(address user) {
        if (kycRegistry != address(0)) {
            if (IKYCRegistry(kycRegistry).isFrozen(user)) revert Frozen();
        }
        _;
    }

    modifier onlyLive() {
        if (!live) revert NotLive();
        _;
    }

    /* ───────── View gating (optional) ───────── */
    function grantHoldersView(address viewer) external onlyOwner {
        allowedViewers[viewer] = true;
        emit HoldersViewerAdded(viewer);
    }

    function revokeHoldersView(address viewer) external onlyOwner {
        allowedViewers[viewer] = false;
        emit HoldersViewerRemoved(viewer);
    }

    function grantHoldersViewBatch(address[] calldata viewers) external onlyOwner {
        for (uint256 i; i < viewers.length; ) {
            allowedViewers[viewers[i]] = true;
            emit HoldersViewerAdded(viewers[i]);
            unchecked { ++i; }
        }
    }

    function _steps() internal view returns (uint256) {
        uint256 s = stepWei;
        if (s == 0) s = 1e18; // defensive; should never be 0 after init
        return totalVolume / s;
    }

    function _piecewise(uint256 steps) internal view returns (uint256 addWeiPerShare) {
        // piecewise linear additive delta over basePrice
        if (steps == 0) return 0;

        uint256 _k1 = k1;
        uint256 _k2 = k2;

        // If not configured yet, treat as flat price
        if (_k1 == 0 || _k2 == 0 || _k2 <= _k1) return 0;

        if (steps <= _k1) {
            return Math.mulDiv(steps, m1, 1);
        }

        uint256 d1 = Math.mulDiv(_k1, m1, 1);

        if (steps <= _k2) {
            uint256 midSteps = steps - _k1;
            return d1 + Math.mulDiv(midSteps, m2, 1);
        }

        uint256 d2 = d1 + Math.mulDiv(_k2 - _k1, m2, 1);
        uint256 lateSteps = steps - _k2;
        return d2 + Math.mulDiv(lateSteps, m3, 1);
    }

    function _price() internal view returns (uint256) {
        uint256 steps = _steps();
        if (steps > maxCurveSteps) revert StepsCap();

        uint256 add = _piecewise(steps);
        // basePrice already validated non-zero in initialize
        return basePrice + add;
    }

    function getCurrentPrice() external view returns (uint256) {
        return _price();
    }

    /* ───────── Solvency invariant ───────── */
    function _requireSolvent() internal view {
        // All ETH must cover both: owed claims + investable reserve
        if (address(this).balance < (claimObligationWei + investmentReserveWei)) revert Solvency();
    }

    /* ───────── Internals: accounting ───────── */
    function _pending(address u) internal view returns (uint256) {
        uint256 acc = accSalesPerShare + accFeesPerShare;
        uint256 entitled = Math.mulDiv(shareBalances[u], acc, PREC);
        uint256 basePend = pending[u];
        if (entitled <= rewardDebt[u]) return basePend;
        return basePend + (entitled - rewardDebt[u]);
    }

    function _distributeFees() internal {
        uint256 amt = unallocatedFees;
        if (amt == 0 || totalShares == 0) return;

        unallocatedFees = 0;

        // This becomes claim liability
        claimObligationWei += amt;
        emit ClaimObligationIncreased(amt, claimObligationWei);

        accFeesPerShare += Math.mulDiv(amt, PREC, totalShares);
        emit SystemFeesDistributed(amt, accFeesPerShare);
    }

    function _updateUser(address u) internal {
        _distributeFees();
        uint256 acc = accSalesPerShare + accFeesPerShare;
        uint256 entitled = Math.mulDiv(shareBalances[u], acc, PREC);
        uint256 rd = rewardDebt[u];
        if (entitled > rd) {
            pending[u] += (entitled - rd);
        }
        rewardDebt[u] = Math.mulDiv(shareBalances[u], acc, PREC);
    }

    function _mint(address to, uint256 amt) internal {
        require(amt > 0, "mint:zero");
        totalShares += amt;
        shareBalances[to] += amt;

        if (!isHolder[to]) {
            isHolder[to] = true;
            holders.push(to);
        }

        rewardDebt[to] = Math.mulDiv(shareBalances[to], (accSalesPerShare + accFeesPerShare), PREC);
    }

    /* ───────── Reserve funding / distribution routing ───────── */

    function _routeInflow(uint256 valueWei, uint16 bps)
        internal
        returns (uint256 toReserveWei, uint256 toDistributeWei)
    {
        if (bps > 10_000) revert BadBps();

        if (bps == 0) {
            toReserveWei = 0;
            toDistributeWei = valueWei;
        } else {
            toReserveWei = Math.mulDiv(valueWei, bps, 10_000);
            toDistributeWei = valueWei - toReserveWei;
        }

        if (toReserveWei > 0) {
            investmentReserveWei += toReserveWei;
            emit ReserveFunded(toReserveWei);
        }

        // Distribute only if there are existing shares (pre-mint distribution rule)
        if (toDistributeWei > 0) {
            if (totalShares == 0) {
                // No existing holders to distribute to => route to reserve (strictly safe)
                investmentReserveWei += toDistributeWei;
                emit ReserveFunded(toDistributeWei);
                toDistributeWei = 0;
            } else {
                // becomes claim liability
                claimObligationWei += toDistributeWei;
                emit ClaimObligationIncreased(toDistributeWei, claimObligationWei);
            }
        }

        _requireSolvent();
    }

    /* ───────── Core: buy / buyFor / claim ───────── */

    function buyShares()
        external
        payable
        nonReentrant
        whenNotPaused
        canParticipate(msg.sender)
        onlyLive
    {
        if (msg.value == 0) revert NoValue();

        // Wallet lifetime cap: applies to external inflow only.
        if (walletCap > 0) {
            uint256 nextVol = lifetimeVolumeIn[msg.sender] + msg.value;
            require(nextVol <= walletCap, "fund:cap");
            lifetimeVolumeIn[msg.sender] = nextVol;
        }

        _updateUser(msg.sender);

        uint256 price = _price();
        uint256 sharesOut = Math.mulDiv(msg.value, PREC, price);
        if (sharesOut == 0 || sharesOut > maxPurchaseShares) revert ShareBounds();

        // Split into reserve + distributable (distributed to existing holders only)
        (uint256 toReserveWei, uint256 toDistributeWei) = _routeInflow(msg.value, reserveBps);

        if (toDistributeWei > 0) {
            // Buy inflows are "sales" distributions
            accSalesPerShare += Math.mulDiv(toDistributeWei, PREC, totalShares);
        }

        _mint(msg.sender, sharesOut);

        totalVolume += msg.value;
        lastPrice = _price();

        emit Purchase(msg.sender, msg.value, sharesOut, lastPrice);

        // silence compiler warning for unused variable (kept for readability)
        (toReserveWei);
    }

    function buySharesFor(address beneficiary)
        external
        payable
        nonReentrant
        whenNotPaused
        canParticipate(beneficiary)
        onlyLive
    {
        if (beneficiary == address(0)) revert NoAuth();
        if (msg.value == 0) revert NoValue();

        // Explicit gate:
        // - if publicBuyForEnabled => anyone can call
        // - else => only minter (and minter must be set)
        if (!publicBuyForEnabled) {
            if (minter == address(0) || msg.sender != minter) revert NoAuth();
        }

        if (walletCap > 0) {
            uint256 nextVol = lifetimeVolumeIn[beneficiary] + msg.value;
            require(nextVol <= walletCap, "fund:cap");
            lifetimeVolumeIn[beneficiary] = nextVol;
        }

        _updateUser(beneficiary);

        uint256 price = _price();
        uint256 sharesOut = Math.mulDiv(msg.value, PREC, price);
        if (sharesOut == 0 || sharesOut > maxPurchaseShares) revert ShareBounds();

        (uint256 toReserveWei, uint256 toDistributeWei) = _routeInflow(msg.value, reserveBps);

        if (toDistributeWei > 0) {
            accSalesPerShare += Math.mulDiv(toDistributeWei, PREC, totalShares);
        }

        _mint(beneficiary, sharesOut);

        totalVolume += msg.value;
        lastPrice = _price();

        emit Purchase(beneficiary, msg.value, sharesOut, lastPrice);

        (toReserveWei);
    }

    function claimRewards()
        external
        nonReentrant
        whenNotPaused
        canExit(msg.sender)
    {
        _updateUser(msg.sender);

        uint256 amt = pending[msg.sender];
        require(amt > 0, "0");
        pending[msg.sender] = 0;

        // Solvency: claims are backed by claimObligationWei
        if (claimObligationWei < amt) revert Solvency();
        claimObligationWei -= amt;
        emit ClaimObligationDecreased(amt, claimObligationWei);

        (bool ok, ) = payable(msg.sender).call{value: amt}("");
        require(ok, "xfer");
        emit RewardsClaimed(msg.sender, amt);

        _requireSolvent();
    }

    /* ───────── Revenue inflow (from FundIngress / other dapps) ─────────
       This does NOT mint shares. It routes value the same way as income:
       reserve part -> investmentReserveWei, remainder -> pro-rata claimable.
    */
    function recordRevenue()
        external
        payable
        nonReentrant
        whenNotPaused
        onlyLive
    {
        // Recommended: call this from FundIngress/routers.
        if (msg.value == 0) revert NoValue();

        // Split revenue
        (, uint256 toDistributeWei) = _routeInflow(msg.value, receiveReserveBps);

        if (toDistributeWei > 0) {
            accFeesPerShare += Math.mulDiv(toDistributeWei, PREC, totalShares);
        }

        emit ReceiveRouted(Math.mulDiv(msg.value, receiveReserveBps, 10_000), toDistributeWei);
    }

    /* ───────── Fees buffer (optional) ─────────
       Keep receive() as a safe sink: route all receive() to unallocatedFees by default
       to avoid surprises. Prefer calling recordRevenue().
    */
    receive() external payable {
        // To avoid unintended routing from random senders, we buffer.
        // Owner can later call distributeFees() to make it claimable.
        if (msg.value > 0) {
            unallocatedFees += msg.value;
            emit SystemFeesBuffered(msg.value);
        }
    }

    function distributeFees() external nonReentrant whenNotPaused {
        _distributeFees();
        _requireSolvent();
    }

    /* ───────── Investment spending (ONLY from reserve) ───────── */
    function invest(address payable to, uint256 amountWei)
        external
        onlyOwner
        nonReentrant
        whenNotPaused
    {
        require(to != address(0), "to=0");
        require(amountWei > 0, "amt=0");
        require(amountWei <= investmentReserveWei, "reserve");

        require(address(this).balance >= amountWei, "bal");

        // Compute new reserve and check solvency after spend
        uint256 newReserve = investmentReserveWei - amountWei;

        // After sending amountWei, contract balance decreases by amountWei.
        // Must still cover claim obligation + remaining reserve.
        uint256 balAfter = address(this).balance - amountWei;
        if (balAfter < (claimObligationWei + newReserve)) revert Solvency();

        investmentReserveWei = newReserve;
        emit ReserveSpent(amountWei);
        emit Invested(to, amountWei, newReserve);

        (bool ok, ) = to.call{value: amountWei}("");
        require(ok, "xfer");
    }

    /* ───────── Legacy functions (DISABLED) ───────── */

    function reinvestRewards() external pure {
        revert NotSupported();
    }

    function redeemShares(uint256) external pure {
        revert NotSupported();
    }

    /* ───────── Admin / Guardian ───────── */

    function pause() external {
        if (msg.sender != owner() && msg.sender != guardian) revert NoAuth();
        _pause();
    }

    function unpause() external {
        if (msg.sender != owner() && msg.sender != guardian) revert NoAuth();
        _unpause();
    }

    function setGuardian(address g) external onlyOwner {
        guardian = g;
        emit GuardianUpdated(g);
    }

    function updatePriceParameters(uint256 newBase, uint256 /* newGF */) external onlyOwner {
        if (newBase == 0) revert BadBase();

        basePrice = newBase;

        // growthFactor is DEPRECATED: kept only for storage compatibility.
        // Pricing uses piecewise params (stepWei,k1,k2,m1,m2,m3).
        emit PriceParametersUpdated(newBase, growthFactor);
    }

    function setVolumeStepWei(uint256 newStepWei) external onlyOwner {
        require(newStepWei > 0, "step=0");

        // Pricing uses stepWei (piecewise). Keep volumeStepWei aligned for backwards ABI/storage.
        stepWei = newStepWei;
        volumeStepWei = newStepWei;

        emit VolumeStepUpdated(newStepWei);
    }

    function setMaxPurchaseShares(uint256 m) external onlyOwner {
        require(m >= 1e18, "bad max");
        maxPurchaseShares = m;
        emit MaxPurchaseUpdated(m);
    }

    function setMinter(address m) external onlyOwner {
        minter = m;
        emit MinterUpdated(m);
    }

    function setPublicBuyForEnabled(bool enabled) external onlyOwner {
        publicBuyForEnabled = enabled;
        emit PublicBuyForUpdated(enabled);
    }

    function setMaxCurveSteps(uint256 newMaxSteps) external onlyOwner {
        require(newMaxSteps > 0, "steps=0");
        maxCurveSteps = newMaxSteps;
        emit MaxCurveStepsUpdated(newMaxSteps);
    }

    function setReserveBps(uint16 newBps) external onlyOwner {
        if (newBps > 10_000) revert BadBps();
        reserveBps = newBps;
        emit ReserveBpsUpdated(newBps);
    }

    function setReceiveReserveBps(uint16 newBps) external onlyOwner {
        if (newBps > 10_000) revert BadBps();
        receiveReserveBps = newBps;
        emit ReceiveReserveBpsUpdated(newBps);
    }

    function setPiecewiseParams(
        uint256 newStepWei,
        uint256 newK1,
        uint256 newK2,
        uint256 newM1,
        uint256 newM2,
        uint256 newM3
    ) external onlyOwner {
        // Basic sanity
        if (newStepWei == 0) revert BadPiecewise();
        if (newK1 == 0 || newK2 == 0 || newK2 <= newK1) revert BadPiecewise();
        if (newK1 > MAX_K || newK2 > MAX_K) revert BadPiecewise();

        // Slopes sanity
        if (newM1 > MAX_SLOPE_WEI_PER_STEP) revert BadPiecewise();
        if (newM2 > MAX_SLOPE_WEI_PER_STEP) revert BadPiecewise();
        if (newM3 > MAX_SLOPE_WEI_PER_STEP) revert BadPiecewise();

        // Enforce monotone non-increasing slopes (price never decreases)
        if (!(newM1 >= newM2 && newM2 >= newM3)) revert BadPiecewise();

        stepWei = newStepWei;
        k1 = newK1;
        k2 = newK2;
        m1 = newM1;
        m2 = newM2;
        m3 = newM3;

        emit PiecewiseParamsUpdated(newStepWei, newK1, newK2, newM1, newM2, newM3);
    }

    /* ───────── Piecewise-linear pricing (NEW) ─────────
    steps = totalVolume / stepWei
    price = basePrice + piecewiseLinear(steps)
    */
    uint256 public stepWei;   // e.g. 0.1 ETH => 1e17
    uint256 public k1;        // first breakpoint in steps
    uint256 public k2;        // second breakpoint in steps (k2 > k1)

    // slopes in wei/share per step (must be monotone: m1 >= m2 >= m3)
    uint256 public m1;
    uint256 public m2;
    uint256 public m3;

    // Hard caps to prevent bricking / overflow-y configs
    uint256 public constant MAX_SLOPE_WEI_PER_STEP = 1e16; // 0.01 ETH/share per step
    uint256 public constant MAX_K = 1_000_000;            // absolute bound for k1/k2 safety (in steps)

    event PiecewiseParamsUpdated(
        uint256 stepWei,
        uint256 k1,
        uint256 k2,
        uint256 m1,
        uint256 m2,
        uint256 m3
    );

    error BadPiecewise();

    /* ───────── Regulatory admin ───────── */

    function setKYCRegistry(address registry) external onlyOwner {
        require(registry == address(0) || registry.code.length > 0, "fund:bad-registry");
        kycRegistry = registry;
        emit KYCRegistryUpdated(registry);
    }

    function setWalletCap(uint256 newCap) external onlyOwner {
        walletCap = newCap;
        emit WalletCapUpdated(newCap);
    }

    function blockAddress(address user, bool blocked) external onlyOwner {
        isBlocked[user] = blocked;
        emit AddressBlocked(user, blocked);
    }

    function resetLifetimeVolume(address user) external onlyOwner {
        lifetimeVolumeIn[user] = 0;
        emit LifetimeVolumeReset(user);
    }

    /* ───────── Importer (genesis privilege) ───────── */

    function openImports() external onlyOwner {
        if (live) revert AlreadyLive();
        if (importsFinalized) revert ImportsAlreadyFinalized();
        importsOpen = true;
        emit ImportsOpened();
    }

    function finalizeImports() external onlyOwner {
        if (live) revert AlreadyLive();
        if (!importsOpen) revert ImportsClosed();
        importsOpen = false;
        importsFinalized = true;
        emit ImportsFinalized();
    }

    function importUsers(
        address[] calldata users,
        uint256[] calldata sharesAmt,
        uint256[] calldata pendWei
    ) external onlyOwner {
        if (live) revert AlreadyLive();
        if (!importsOpen) revert ImportsClosed();

        uint256 L = users.length;
        if (L != sharesAmt.length || L != pendWei.length) revert Len();

        uint256 acc = accSalesPerShare + accFeesPerShare;

        for (uint256 i; i < L; ) {
            address u = users[i];
            uint256 s = sharesAmt[i];
            uint256 pw = pendWei[i];

            if (u == address(0)) revert NoAuth();
            if (imported[u]) revert AlreadyImported();
            imported[u] = true;

            if (s > 0) {
                totalShares += s;
                shareBalances[u] += s;

                if (!isHolder[u]) {
                    isHolder[u] = true;
                    holders.push(u);
                }

                rewardDebt[u] = Math.mulDiv(shareBalances[u], acc, PREC);
            }

            if (pw > 0) {
                pending[u] += pw;

                // imported pending is liability
                claimObligationWei += pw;
                emit ClaimObligationIncreased(pw, claimObligationWei);
            }

            emit Imported(u, s, pw);

            unchecked { ++i; }
        }

        _requireSolvent();
    }

    function goLive() external onlyOwner {
        if (live) revert AlreadyLive();
        if (!importsFinalized) revert ImportsAlreadyFinalized(); // (kept for storage ABI compatibility)
        require(totalShares > 0, "genesis:empty");
        live = true;
        emit LiveEnabled();
        _requireSolvent();
    }

    /* ───────── Accounting maintenance (ghost ETH) ───────── */

    function accountedBalance() public view returns (uint256) {
        // Everything that is "spoken for"
        return investmentReserveWei + claimObligationWei + unallocatedFees;
    }

    function unaccountedBalance() public view returns (uint256) {
        uint256 bal = address(this).balance;
        uint256 accd = accountedBalance();
        if (bal <= accd) return 0;
        return bal - accd;
    }

    function sweepUnaccounted(bool toReserve) external onlyOwner nonReentrant {
        uint256 amt = unaccountedBalance();
        if (amt == 0) return;

        if (toReserve) {
            investmentReserveWei += amt;
            emit ReserveFunded(amt);
        } else {
            unallocatedFees += amt;
            emit SystemFeesBuffered(amt);
        }

        emit UnaccountedSwept(amt, toReserve);
        _requireSolvent();
    }

    /* ───────── Export views ───────── */

    struct UserSnapshot {
        address user;
        uint256 shares;
        uint256 pendingWei;
        uint256 rewardDebtSnap;
    }

    function getUserSnapshot(address u) public view returns (UserSnapshot memory s) {
        uint256 acc = accSalesPerShare + accFeesPerShare;
        uint256 entitled = Math.mulDiv(shareBalances[u], acc, PREC);
        uint256 pend = pending[u] + (entitled > rewardDebt[u] ? (entitled - rewardDebt[u]) : 0);

        s = UserSnapshot({
            user: u,
            shares: shareBalances[u],
            pendingWei: pend,
            rewardDebtSnap: rewardDebt[u]
        });
    }

    function emitSnapshots(uint256 from, uint256 max) external onlyOwner {
        uint256 n = holders.length;
        if (from >= n || max == 0) return;

        uint256 to = from + max;
        if (to > n) to = n;

        for (uint256 i = from; i < to; ) {
            address u = holders[i];
            UserSnapshot memory s = getUserSnapshot(u);
            emit UserSnapshotEmitted(s.user, s.shares, s.pendingWei);
            unchecked { ++i; }
        }
    }

    function getGlobalStats()
        external
        view
        returns (
            uint256 price,
            uint256 last,
            uint256 volume,
            uint256 numHolders,
            uint256 reserveWei,
            uint256 obligationWei,
            uint256 bufferedWei,
            uint256 unaccountedWei_
        )
    {
        price = _price();
        last = lastPrice;
        volume = totalVolume;
        numHolders = holders.length;
        reserveWei = investmentReserveWei;
        obligationWei = claimObligationWei;
        bufferedWei = unallocatedFees;
        unaccountedWei_ = unaccountedBalance();
    }

    function getUserStats(address u)
        external
        view
        returns (uint256 shares, uint256 claimable)
    {
        shares = shareBalances[u];
        claimable = _pending(u);
    }

    function getHoldersWithBalances(uint256 from, uint256 max)
        external
        view
        returns (address[] memory addrs, uint256[] memory sharesArr)
    {
        uint256 n = holders.length;
        if (from >= n || max == 0) {
            // return properly initialized empty arrays
            return (new address[](0), new uint256[](0));
        }

        uint256 to = from + max;
        if (to > n) to = n;
        uint256 L = to - from;

        addrs = new address[](L);
        sharesArr = new uint256[](L);

        for (uint256 i; i < L; ) {
            address u = holders[from + i];
            addrs[i] = u;
            sharesArr[i] = shareBalances[u];
            unchecked { ++i; }
        }
    }


    function recoverERC20(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        require(to != address(0), "to=0");
        IERC20Upgradeable(token).safeTransfer(to, amount);
        emit ERC20Recovered(token, to, amount);
    }

    /* ───────── Storage gap ───────── */
    uint256[72] private __gap;
}
