//SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {IERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/interfaces/IERC4626Upgradeable.sol";

import {IGmxRewardRouter} from "../interfaces/IGmxRewardRouter.sol";
import {IGlpManager, IGMXVault} from "../interfaces/IGlpManager.sol";
import {IBaklavaGlpVaultRouter} from "../interfaces/IBaklavaGlpVaultRouter.sol";
import {Governable} from "../common/Governable.sol";
import {IWhitelistController} from "../interfaces/IWhitelistController.sol";
import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";
import {IBaklavaGlpLeverageStrategy} from "../interfaces/IBaklavaGlpLeverageStrategy.sol";
import {IYakStrategyV2} from "../interfaces/IYakStrategyV2.sol";
import {IBaklavaGlpStableVault} from "../interfaces/IBaklavaGlpStableVault.sol";
import {IBaklavaGlpVault} from "../interfaces/IBaklavaGlpVault.sol";

contract GlpAdapter is Initializable, Governable, ReentrancyGuardUpgradeable, UUPSUpgradeable {

    IBaklavaGlpVaultRouter public vaultRouter;
    IGmxRewardRouter public gmxRouter;
    IAggregatorV3 private constant oracle = IAggregatorV3(0xF096872672F44d6EBA71458D74fe67F9a77a23B9);
    IERC20Upgradeable private constant glp = IERC20Upgradeable(0xaE64d55a6f09E4263421737397D1fdFA71896a69);
    IERC20Upgradeable private constant usdc = IERC20Upgradeable(0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E);
    IYakStrategyV2 private constant yrt = IYakStrategyV2(0x9f637540149f922145c06e1aa3f38dcDc32Aff5C);
    IWhitelistController public controller;
    IBaklavaGlpLeverageStrategy public strategy;
    IBaklavaGlpStableVault public stableVault;

    uint256 public flexibleTotalCap;
    bool public useFlexibleCap;

    mapping(address => bool) public isValid;

    uint256 public constant BASIS_POINTS = 1e12;
    IBaklavaGlpVault public glpVault;
    IERC20Upgradeable public sglp;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _governor,
        address[] memory _tokens, 
        address _controller, 
        address _gmxRouter,
        address _strategy, 
        address _stableVault
    ) initializer public {
        uint8 i = 0;
        for (; i < _tokens.length;) {
            _editToken(_tokens[i], true);
            unchecked {
                i++;
            }
        }
        gmxRouter = IGmxRewardRouter(_gmxRouter);
        controller = IWhitelistController(_controller);
        strategy = IBaklavaGlpLeverageStrategy(_strategy);
        stableVault = IBaklavaGlpStableVault(_stableVault);

        __Governable_init(_governor, msg.sender);
        __ReentrancyGuard_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();
    }


    function zapToGlp(address _token, uint256 _amount)
        external
        nonReentrant
        validToken(_token)
        returns (uint256)
    {
        _onlyEOA();

        IERC20Upgradeable(_token).transferFrom(msg.sender, address(this), _amount);

        IERC20Upgradeable(_token).approve(gmxRouter.glpManager(), _amount);
        uint256 mintedGlp = gmxRouter.mintAndStakeGlp(_token, _amount, 0, 0);

        glp.approve(address(vaultRouter), mintedGlp);
        uint256 receipts = vaultRouter.depositGlp(mintedGlp, msg.sender, true, true);

        return receipts;
    }

    function zapToGlpEth() external payable nonReentrant returns (uint256) {
        _onlyEOA();

        uint256 mintedGlp = gmxRouter.mintAndStakeGlpETH{value: msg.value}(0, 0);

        glp.approve(address(vaultRouter), mintedGlp);

        uint256 receipts = vaultRouter.depositGlp(mintedGlp, msg.sender, true, true);

        return receipts;
    }

    function redeemGlpBasket(uint256 _shares, address _token, bool _native)
        external
        nonReentrant
        validToken(_token)
        returns (uint256)
    {
        _onlyEOA();

        uint256 assetsReceived = vaultRouter.redeemGlpAdapter(_shares, true, _token, msg.sender, _native);

        return assetsReceived;
    }

    function redeemYrt(uint256 _shares)
        external
        nonReentrant
        returns (uint256)
    {
        _onlyEOA();

        uint256 assetsReceived = vaultRouter.redeemGlpAdapter(_shares, true, address(yrt), msg.sender, false);

        sglp.approve(address(yrt), assetsReceived);
        yrt.deposit(assetsReceived);

        uint256 yrtAmount = yrt.balanceOf(address(this));

        yrt.transfer(msg.sender, yrtAmount);

        return assetsReceived;
    }

    function depositGlp(uint256 _assets) external nonReentrant returns (uint256) {
        _onlyEOA();

        glp.transferFrom(msg.sender, address(this), _assets);

        glp.approve(address(vaultRouter), _assets);

        uint256 receipts = vaultRouter.depositGlp(_assets, msg.sender, true, true);

        return receipts;
    }

    function depositStable(uint256 _assets) external nonReentrant returns (uint256) {
        _onlyEOA();

        if (useFlexibleCap) {
            _checkUsdcCap(_assets);
        }

        usdc.transferFrom(msg.sender, address(this), _assets);

        usdc.approve(address(vaultRouter), _assets);

        uint256 receipts = vaultRouter.depositStable(_assets, msg.sender, true);

        return receipts;
    }

    function depositYrt(uint256 _assets) external nonReentrant returns (uint256) {
        _onlyEOA();

        yrt.transferFrom(msg.sender, address(this), _assets);

        yrt.withdraw(_assets);
        
        uint256 glpAmount = glp.balanceOf(address(this));

        glp.approve(address(vaultRouter), glpAmount);

        uint256 receipts = vaultRouter.depositGlp(glpAmount, msg.sender, true, true);

        return receipts;
    }


  // ============ Governor Functions ============

    function updateGmxRouter(address _gmxRouter) external onlyRole(GOVERNOR_ROLE) {
        gmxRouter = IGmxRewardRouter(_gmxRouter);
    }

    function updateVaultRouter(address _vaultRouter) external onlyRole(GOVERNOR_ROLE) {
        vaultRouter = IBaklavaGlpVaultRouter(_vaultRouter);
    }

    function updateGlpVault(address _glpVault) external onlyRole(GOVERNOR_ROLE) {
        glpVault = IBaklavaGlpVault(_glpVault);
    }

    function updateStrategy(address _strategy) external onlyRole(GOVERNOR_ROLE) {
        strategy = IBaklavaGlpLeverageStrategy(_strategy);
    }

    function updateSglp(address _sglp) external onlyRole(GOVERNOR_ROLE) {
        sglp = IERC20Upgradeable(_sglp);
    }

    function toggleFlexibleCap(bool _status) external onlyRole(GOVERNOR_ROLE) {
        useFlexibleCap = _status;
    }

    function updateFlexibleCap(uint256 _newAmount) public onlyRole(GOVERNOR_ROLE) {
        //18 decimals -> $1mi = 1_000_000e18
        flexibleTotalCap = _newAmount;
    }

    function editToken(address _token, bool _valid) external onlyRole(GOVERNOR_ROLE) {
        _editToken(_token, _valid);
    }


    // ============ Internal Functions ============
    
    function _editToken(address _token, bool _valid) internal {
        isValid[_token] = _valid;
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        onlyRole(OWNER_ROLE)
        override
    {}

  // ============ Public View Functions ============

    function getFlexibleCap() public view returns (uint256) {
        return flexibleTotalCap; //18 decimals
    }

    function usingFlexibleCap() public view returns (bool) {
        return useFlexibleCap;
    }

    function getUsdcCap() public view returns (uint256 usdcCap) {
        uint256 strategyTarget = strategy.leverageConfig().target;
        usdcCap = (flexibleTotalCap * (strategyTarget - BASIS_POINTS)) / strategyTarget;
    }

    function belowCap(uint256 _amount) public view returns (bool) {
        uint256 increaseDecimals = 10;
        (, int256 lastPrice,,,) = oracle.latestRoundData(); //8 decimals
        uint256 price = uint256(lastPrice) * (10 ** increaseDecimals); //18 DECIMALS
        uint256 usdcCap = getUsdcCap(); //18 decimals
        uint256 stableTvl = stableVault.tvl(); //18 decimals
        uint256 denominator = 1e6;

        uint256 notional = (price * _amount) / denominator;

        if (stableTvl + notional > usdcCap) {
            return false;
        }

        return true;
    }

  // ============ Private View Functions ============

    function _onlyEOA() private view {
        if (msg.sender != tx.origin && !controller.isWhitelistedContract(msg.sender)) {
            revert NotWhitelisted();
        }
    }

    function _checkUsdcCap(uint256 _amount) private view {
        if (!belowCap(_amount)) {
            revert OverUsdcCap();
        }
    }

    modifier validToken(address _token) {
        require(isValid[_token], "Invalid token.");
        _;
    }

    error NotHatlisted();
    error OverUsdcCap();
    error NotWhitelisted();
}