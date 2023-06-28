// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import { ERC4626, ERC20, IERC20, IERC4626 } from "openzeppelin/token/ERC20/extensions/ERC4626.sol";
import { ERC20Permit, IERC20Permit } from "openzeppelin/token/ERC20/extensions/draft-ERC20Permit.sol";
import { SafeERC20 } from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import { Math } from "openzeppelin/utils/math/Math.sol";

import { Ownable } from "owner-manager-contracts/Ownable.sol";
import { LiquidationPair } from "v5-liquidator/LiquidationPair.sol";
import { ILiquidationSource } from "v5-liquidator-interfaces/ILiquidationSource.sol";
import { PrizePool } from "v5-prize-pool/PrizePool.sol";
import { TwabController } from "v5-twab-controller/TwabController.sol";
import { Hook } from "src/interfaces/IVaultHooks.sol";

/// @notice Emitted when the TWAB controller is set to the zero address
error TwabControllerZeroAddress();

/// @notice Emitted when the Yield Vault is set to the zero address
error YieldVaultZeroAddress();

/// @notice Emitted when the Prize Pool is set to the zero address
error PrizePoolZeroAddress();

/// @notice Emitted when the Owner is set to the zero address
error OwnerZeroAddress();

/// @notice Emitted when the amount being deposited for the receiver is greater than the max amount allowed
/// @param receiver The receiver of the deposit
/// @param amount The amount to deposit
/// @param max The max deposit amount allowed
error DepositMoreThanMax(address receiver, uint256 amount, uint256 max);

/// @notice Emitted when the amount being withdrawn for the owner is greater than the max amount allowed
/// @param owner The owner of the assets
/// @param amount The amount to withdraw
/// @param max The max withdrawable amount
error WithdrawMoreThanMax(address owner, uint256 amount, uint256 max);

/// @notice Emitted when the amount being redeemed for owner is greater than the max allowed amount
/// @param owner The owner of the assets
/// @param amount The amount to redeem
/// @param max The max redeemable amount
error RedeemMoreThanMax(address owner, uint256 amount, uint256 max);

/// @notice Emitted during the liquidation process when the caller is not the liquidation pair contract
/// @param caller The caller address
/// @param liquidationPair The LP address
error LiquidationCallerNotLP(address caller, address liquidationPair);

/// @notice Emitted during the liquidation process when the token in is not the prize token
/// @param tokenIn The provided tokenIn address
/// @param prizeToken The prize token address
error LiquidationTokenInNotPrizeToken(address tokenIn, address prizeToken);

/// @notice Emitted during the liquidation process when the token out is not the vault share token
/// @param tokenOut The provided tokenOut address
/// @param vaultShare The vault share token address
error LiquidationTokenOutNotVaultShare(address tokenOut, address vaultShare);

/// @notice Emitted during the liquidation process when the liquidation amount out is zero
error LiquidationAmountOutZero();

/// @notice Emitted during the liquidation process if the amount out is greater than the available yield
/// @param amountOut The amount out
/// @param availableYield The available yield
error LiquidationAmountOutGTYield(uint256 amountOut, uint256 availableYield);

/// @notice Emitted when the vault is under-collateralized
error VaultUnderCollateralized();

/// @notice Emitted when the target token is not supported for a given token address
/// @param token The unsupported token address
error TargetTokenNotSupported(address token);

/// @notice Emitted when the caller is not the prize claimer
/// @param caller The caller address
/// @param claimer The claimer address
error CallerNotClaimer(address caller, address claimer);

/// @notice Emitted when the minted yield exceeds the yield fee supply
/// @param shares The shares to mint
/// @param yieldFeeTotalSupply The accrued yield fee available
error YieldFeeGTAvailable(uint256 shares, uint256 yieldFeeTotalSupply);

/// @notice Emitted when the Liquidation Pair being set is the zero address
error LPZeroAddress();

/// @notice Emitted when the amount of shares being minted to receiver is greater than the max amount allowed
/// @param shares The shares being minted
/// @param receiver The receiver address
/// @param max The max amount of shares that can be minted to the receiver
error MintGTMax(uint256 shares, address receiver, uint256 max);

/// @notice Emitted when the yield fee percentage being set is greater than the fee precision
/// @param yieldFeePercentage The yield fee percentage in integer format
/// @param feePrecision The fee precision
error YieldFeePercentageGTPrecision(uint256 yieldFeePercentage, uint256 feePrecision);

/**
 * @title  PoolTogether V5 Vault
 * @author PoolTogether Inc Team
 * @notice Vault extends the ERC4626 standard and is the entry point for users interacting with a V5 pool.
 *         Users deposit an underlying asset (i.e. USDC) in this contract and receive in exchange an ERC20 token
 *         representing their share of deposit in the vault.
 *         Underlying assets are then deposited in a YieldVault to generate yield.
 *         This yield is sold for prize tokens (i.e. POOL) via the Liquidator and captured by the PrizePool to be awarded to depositors.
 * @dev    Balances are stored in the TwabController contract.
 */
contract Vault is ERC4626, ERC20Permit, ILiquidationSource, Ownable {
  using Math for uint256;
  using SafeERC20 for IERC20;

  /* ============ Events ============ */

  /**
   * @notice Emitted when a new Vault has been deployed.
   * @param asset Address of the underlying asset used by the vault
   * @param name Name of the ERC20 share minted by the vault
   * @param symbol Symbol of the ERC20 share minted by the vault
   * @param twabController Address of the TwabController used to keep track of balances
   * @param yieldVault Address of the ERC4626 vault in which assets are deposited to generate yield
   * @param prizePool Address of the PrizePool that computes prizes
   * @param claimer Address of the claimer
   * @param yieldFeeRecipient Address of the yield fee recipient
   * @param yieldFeePercentage Yield fee percentage
   * @param owner Address of the owner
   */
  event NewVault(
    IERC20 indexed asset,
    string name,
    string symbol,
    TwabController twabController,
    IERC4626 indexed yieldVault,
    PrizePool indexed prizePool,
    address claimer,
    address yieldFeeRecipient,
    uint256 yieldFeePercentage,
    address owner
  );

  /**
   * @notice Emitted when a new claimer has been set.
   * @param previousClaimer Address of the previous claimer
   * @param newClaimer Address of the new claimer
   */
  event ClaimerSet(address previousClaimer, address newClaimer);

  /**
   * @notice Emitted when a new LiquidationPair has been set.
   * @param newLiquidationPair Address of the new liquidationPair
   */
  event LiquidationPairSet(LiquidationPair newLiquidationPair);

  /**
   * @notice Emitted when yield fee is minted to the yield recipient.
   * @param caller Address that called the function
   * @param recipient Address receiving the Vault shares
   * @param shares Amount of shares minted to `recipient`
   */
  event MintYieldFee(address indexed caller, address indexed recipient, uint256 shares);

  /**
   * @notice Emitted when a new yield fee recipient has been set.
   * @param previousYieldFeeRecipient Address of the previous yield fee recipient
   * @param newYieldFeeRecipient Address of the new yield fee recipient
   */
  event YieldFeeRecipientSet(address previousYieldFeeRecipient, address newYieldFeeRecipient);

  /**
   * @notice Emitted when a new yield fee percentage has been set.
   * @param previousYieldFeePercentage Previous yield fee percentage
   * @param newYieldFeePercentage New yield fee percentage
   */
  event YieldFeePercentageSet(uint256 previousYieldFeePercentage, uint256 newYieldFeePercentage);

  /**
   * @notice Emitted when a user sponsor the Vault.
   * @param caller Address that called the function
   * @param receiver Address receiving the Vault shares
   * @param assets Amount of assets deposited into the Vault
   * @param shares Amount of shares minted to `receiver`
   */
  event Sponsor(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);

  /* ============ Variables ============ */

  /// @notice Address of the TwabController used to keep track of balances.
  TwabController private immutable _twabController;

  /// @notice Address of the ERC4626 vault generating yield.
  IERC4626 private immutable _yieldVault;

  /// @notice Address of the PrizePool that computes prizes.
  PrizePool private immutable _prizePool;

  /// @notice Address of the claimer.
  address private _claimer;

  /// @notice Address of the LiquidationPair used to liquidate yield for prize token.
  LiquidationPair private _liquidationPair;

  /// @notice Underlying asset unit (i.e. 10 ** 18 for DAI).
  uint256 private _assetUnit;

  /// @notice Most recent exchange rate recorded when burning or minting Vault shares.
  uint256 private _lastRecordedExchangeRate;

  /// @notice Yield fee percentage represented in 9 decimal places and in decimal notation (i.e. 10000000 = 0.01 = 1%).
  uint256 private _yieldFeePercentage;

  /// @notice Address of the yield fee recipient that receives the fee amount when yield is captured.
  address private _yieldFeeRecipient;

  /// @notice Total supply of accrued yield fee.
  uint256 private _yieldFeeTotalSupply;

  /// @notice Fee precision denominated in 9 decimal places and used to calculate yield fee percentage.
  uint256 private constant FEE_PRECISION = 1e9;

  /// @notice Allows users to add hooks that execute code when prizes are won
  mapping(address => Hook) public hooks;

  /* ============ Constructor ============ */

  /**
   * @notice Vault constructor
   * @dev `claimer` can be set to address zero if none is available yet.
   * @param _asset Address of the underlying asset used by the vault
   * @param _name Name of the ERC20 share minted by the vault
   * @param _symbol Symbol of the ERC20 share minted by the vault
   * @param twabController_ Address of the TwabController used to keep track of balances
   * @param yieldVault_ Address of the ERC4626 vault in which assets are deposited to generate yield
   * @param prizePool_ Address of the PrizePool that computes prizes
   * @param claimer_ Address of the claimer
   * @param yieldFeeRecipient_ Address of the yield fee recipient
   * @param yieldFeePercentage_ Yield fee percentage
   * @param _owner Address that will gain ownership of this contract
   */
  constructor(
    IERC20 _asset,
    string memory _name,
    string memory _symbol,
    TwabController twabController_,
    IERC4626 yieldVault_,
    PrizePool prizePool_,
    address claimer_,
    address yieldFeeRecipient_,
    uint256 yieldFeePercentage_,
    address _owner
  ) ERC4626(_asset) ERC20(_name, _symbol) ERC20Permit(_name) Ownable(_owner) {
    if (address(twabController_) == address(0)) revert TwabControllerZeroAddress();
    if (address(yieldVault_) == address(0)) revert YieldVaultZeroAddress();
    if (address(prizePool_) == address(0)) revert PrizePoolZeroAddress();
    if (address(_owner) == address(0)) revert OwnerZeroAddress();

    _twabController = twabController_;
    _yieldVault = yieldVault_;
    _prizePool = prizePool_;

    _setClaimer(claimer_);
    _setYieldFeeRecipient(yieldFeeRecipient_);
    _setYieldFeePercentage(yieldFeePercentage_);

    _assetUnit = 10 ** super.decimals();

    // Approve once for max amount
    _asset.safeApprove(address(yieldVault_), type(uint256).max);

    emit NewVault(
      _asset,
      _name,
      _symbol,
      twabController_,
      yieldVault_,
      prizePool_,
      claimer_,
      yieldFeeRecipient_,
      yieldFeePercentage_,
      _owner
    );
  }

  /* ============ External Functions ============ */

  /* ============ View Functions ============ */

  /// @inheritdoc ILiquidationSource
  function liquidatableBalanceOf(address _token) public view override returns (uint256) {
    return _liquidatableBalanceOf(_token);
  }

  /**
   * @notice Total available yield amount accrued by this vault.
   * @dev This amount includes the liquidatable yield + yield fee amount.
   * @dev The available yield is equal to the total amount of assets managed by this Vault
   *      minus the total amount of assets supplied to the Vault and yield fees allocated to `_yieldFeeRecipient`.
   * @dev If `_sharesToAssets` is greater than `_assets`, it means that the Vault is undercollateralized.
   *      We must not mint more shares than underlying assets available so we return 0.
   * @return uint256 Total yield amount
   */
  function availableYieldBalance() public view returns (uint256) {
    uint256 _assets = _totalAssets();
    uint256 _sharesToAssets = _convertToAssets(_totalShares(), Math.Rounding.Down);

    return _sharesToAssets > _assets ? 0 : _assets - _sharesToAssets;
  }

  /**
   * @notice Get the available yield fee amount accrued by this vault.
   * @return uint256 Yield fee amount
   */
  function availableYieldFeeBalance() public view returns (uint256) {
    uint256 _availableYield = availableYieldBalance();

    if (_availableYield != 0 && _yieldFeePercentage != 0) {
      return _availableYieldFeeBalance(_availableYield);
    }

    return 0;
  }

  /// @inheritdoc ERC20
  function balanceOf(
    address _account
  ) public view virtual override(ERC20, IERC20) returns (uint256) {
    return _twabController.balanceOf(address(this), _account);
  }

  /// @inheritdoc ERC4626
  function decimals() public view virtual override(ERC4626, ERC20) returns (uint8) {
    return super.decimals();
  }

  /// @inheritdoc ERC4626
  function totalAssets() public view virtual override returns (uint256) {
    return _totalAssets();
  }

  /// @inheritdoc ERC20
  function totalSupply() public view virtual override(ERC20, IERC20) returns (uint256) {
    return _totalSupply();
  }

  /**
   * @notice Current exchange rate between the Vault shares and
   *         the total amount of underlying assets withdrawable from the YieldVault.
   * @return uint256 Current exchange rate
   */
  function exchangeRate() public view returns (uint256) {
    return _currentExchangeRate();
  }

  /**
   * @notice Check if the Vault is collateralized.
   * @return bool True if the vault is collateralized, false otherwise
   */
  function isVaultCollateralized() public view returns (bool) {
    return _isVaultCollateralized();
  }

  /**
   * @inheritdoc ERC4626
   * @dev We use type(uint112).max cause this is the type used to store balances in TwabController.
   */
  function maxDeposit(address) public view virtual override returns (uint256) {
    return _isVaultCollateralized() ? type(uint112).max : 0;
  }

  /**
   * @inheritdoc ERC4626
   * @dev We use type(uint112).max cause this is the type used to store balances in TwabController.
   */
  function maxMint(address) public view virtual override returns (uint256) {
    return _isVaultCollateralized() ? type(uint112).max : 0;
  }

  /* ============ Deposit Functions ============ */

  /// @inheritdoc ERC4626
  function deposit(uint256 _assets, address _receiver) public virtual override returns (uint256) {
    if (_assets > maxDeposit(_receiver))
      revert DepositMoreThanMax(_receiver, _assets, maxDeposit(_receiver));

    uint256 _shares = _convertToShares(_assets, Math.Rounding.Down);
    _deposit(msg.sender, _receiver, _assets, _shares);

    return _shares;
  }

  /**
   * @notice Approve underlying asset with permit, deposit into the Vault and mint Vault shares to `_receiver`.
   * @param _assets Amount of assets to approve and deposit
   * @param _receiver Address of the receiver of the vault shares
   * @param _deadline Timestamp after which the approval is no longer valid
   * @param _v V part of the secp256k1 signature
   * @param _r R part of the secp256k1 signature
   * @param _s S part of the secp256k1 signature
   * @return uint256 Amount of Vault shares minted to `_receiver`.
   */
  function depositWithPermit(
    uint256 _assets,
    address _receiver,
    uint256 _deadline,
    uint8 _v,
    bytes32 _r,
    bytes32 _s
  ) external returns (uint256) {
    _permit(IERC20Permit(asset()), msg.sender, address(this), _assets, _deadline, _v, _r, _s);
    return deposit(_assets, _receiver);
  }

  /// @inheritdoc ERC4626
  function mint(uint256 _shares, address _receiver) public virtual override returns (uint256) {
    uint256 _assets = _beforeMint(_shares, _receiver);

    _deposit(msg.sender, _receiver, _assets, _shares);

    return _assets;
  }

  /**
   * @notice Approve underlying asset with permit, deposit into the Vault and mint Vault shares to `_receiver`.
   * @param _shares Amount of shares to mint to `_receiver`
   * @param _receiver Address of the receiver of the vault shares
   * @param _deadline Timestamp after which the approval is no longer valid
   * @param _v V part of the secp256k1 signature
   * @param _r R part of the secp256k1 signature
   * @param _s S part of the secp256k1 signature
   * @return uint256 Amount of assets deposited into the Vault.
   */
  function mintWithPermit(
    uint256 _shares,
    address _receiver,
    uint256 _deadline,
    uint8 _v,
    bytes32 _r,
    bytes32 _s
  ) external returns (uint256) {
    uint256 _assets = _beforeMint(_shares, _receiver);

    _permit(IERC20Permit(asset()), msg.sender, address(this), _assets, _deadline, _v, _r, _s);
    _deposit(msg.sender, _receiver, _assets, _shares);

    return _assets;
  }

  /**
   * @notice Deposit assets into the Vault and delegate to the sponsorship address.
   * @param _assets Amount of assets to deposit
   * @param _receiver Address of the receiver of the vault shares
   * @return uint256 Amount of shares minted to `_receiver`.
   */
  function sponsor(uint256 _assets, address _receiver) external returns (uint256) {
    return _sponsor(_assets, _receiver);
  }

  /**
   * @notice Deposit assets into the Vault and delegate to the sponsorship address.
   * @param _assets Amount of assets to deposit
   * @param _receiver Address of the receiver of the vault shares
   * @param _deadline Timestamp after which the approval is no longer valid
   * @param _v V part of the secp256k1 signature
   * @param _r R part of the secp256k1 signature
   * @param _s S part of the secp256k1 signature
   * @return uint256 Amount of shares minted to `_receiver`.
   */
  function sponsorWithPermit(
    uint256 _assets,
    address _receiver,
    uint256 _deadline,
    uint8 _v,
    bytes32 _r,
    bytes32 _s
  ) external returns (uint256) {
    _permit(IERC20Permit(asset()), msg.sender, address(this), _assets, _deadline, _v, _r, _s);
    return _sponsor(_assets, _receiver);
  }

  /* ============ Withdraw Functions ============ */

  /// @inheritdoc ERC4626
  function withdraw(
    uint256 _assets,
    address _receiver,
    address _owner
  ) public virtual override returns (uint256) {
    if (_assets > maxWithdraw(_owner))
      revert WithdrawMoreThanMax(_owner, _assets, maxWithdraw(_owner));

    uint256 _shares = _convertToShares(_assets, Math.Rounding.Up);
    _withdraw(msg.sender, _receiver, _owner, _assets, _shares);

    return _shares;
  }

  /// @inheritdoc ERC4626
  function redeem(
    uint256 _shares,
    address _receiver,
    address _owner
  ) public virtual override returns (uint256) {
    if (_shares > maxRedeem(_owner)) revert RedeemMoreThanMax(_owner, _shares, maxRedeem(_owner));

    uint256 _assets = _convertToAssets(_shares, Math.Rounding.Down);
    _withdraw(msg.sender, _receiver, _owner, _assets, _shares);

    return _assets;
  }

  /* ============ Liquidate Functions ============ */

  /**
   * @inheritdoc ILiquidationSource
   * @dev User provides prize tokens and receives in exchange Vault shares.
   * @dev The yield fee can serve as a buffer in case of undercollateralization of the Vault.
   * @dev If assets are living in the Vault, we deposit it in the YieldVault.
   */
  function liquidate(
    address _account,
    address _tokenIn,
    uint256 _amountIn,
    address _tokenOut,
    uint256 _amountOut
  ) public virtual override returns (bool) {
    _requireVaultCollateralized();
    if (msg.sender != address(_liquidationPair))
      revert LiquidationCallerNotLP(msg.sender, address(_liquidationPair));
    if (_tokenIn != address(_prizePool.prizeToken()))
      revert LiquidationTokenInNotPrizeToken(_tokenIn, address(_prizePool.prizeToken()));
    if (_tokenOut != address(this))
      revert LiquidationTokenOutNotVaultShare(_tokenOut, address(this));
    if (_amountOut == 0) revert LiquidationAmountOutZero();

    uint256 _liquidableYield = _liquidatableBalanceOf(_tokenOut);
    if (_amountOut > _liquidableYield)
      revert LiquidationAmountOutGTYield(_amountOut, _liquidableYield);

    _prizePool.contributePrizeTokens(address(this), _amountIn);

    if (_yieldFeePercentage != 0) {
      _increaseYieldFeeBalance(
        (_amountOut * FEE_PRECISION) / (FEE_PRECISION - _yieldFeePercentage) - _amountOut
      );
    }

    uint256 _vaultAssets = IERC20(asset()).balanceOf(address(this));

    if (_vaultAssets != 0 && _amountOut >= _vaultAssets) {
      _yieldVault.deposit(_vaultAssets, address(this));
    }

    _mint(_account, _amountOut);

    return true;
  }

  /// @inheritdoc ILiquidationSource
  function targetOf(address _token) external view returns (address) {
    if (_token != _liquidationPair.tokenIn()) revert TargetTokenNotSupported(_token);
    return address(_prizePool);
  }

  /* ============ Claim Functions ============ */

  /**
   * @notice Claim prize for `_user`.
   * @dev Callable by anyone if claimer has not been set.
   * @dev If claimer has been set:
   *      - caller needs to be claimer address
   *      - If auto claim is disabled for `_user`:
   *        - caller can be any address except claimer address
   * @param _tier Tier to claim prize for
   * @param _winners Addresses of the winners to claim prizes
   * @param _prizeIndices The prizes to claim for each winner
   * @param _feePerClaim Fee to be charged per prize claim
   * @param _claimFeeRecipient Address that will receive `_claimFee` amount
   */
  function claimPrizes(
    uint8 _tier,
    address[] calldata _winners,
    uint32[][] calldata _prizeIndices,
    uint96 _feePerClaim,
    address _claimFeeRecipient
  ) external returns (uint256) {
    if (msg.sender != address(_claimer)) revert CallerNotClaimer(msg.sender, address(_claimer));

    for (uint w = 0; w < _winners.length; w++) {
      uint prizeIndicesLength = _prizeIndices[w].length;
      for (uint p = 0; p < prizeIndicesLength; p++) {
        _claimPrize(w, _tier, _prizeIndices[w][p], _feePerClaim, _claimFeeRecipient);
      }
    }
  }

  function _claimPrize(address _winner, uint8 _tier, uint32 _prizeIndex, uint96 _fee, address _feeRecipient) internal {
    Hook memory hook = hooks[_winner];
    address recipient;
    if (hook.useBeforeClaimHook) {
      recipient = hook.hooks.beforeClaimPrize(_winner, _tier, _prizeIndex);
    } else {
      recipient = _winner;
    }

    uint prizeTotal = _prizePool.claimPrizes(_winner, _tier, _prizeIndex, _fee, _feeRecipient);

    if (hook.useAfterClaimHook) {
      hook.hooks.afterClaimPrize(_winner, _tier, _prizeIndex, prizeTotal - _fee, recipient);
    }

    return prizeTotal;
  }

  /**
   * @notice Mint Vault shares to the yield fee `_recipient`.
   * @dev Will revert if the Vault is undercollateralized
   *      or if the `_shares` are greater than the accrued `_yieldFeeTotalSupply`.
   * @param _shares Amount of shares to mint
   * @param _recipient Address of the yield fee recipient
   */
  function mintYieldFee(uint256 _shares, address _recipient) external {
    _requireVaultCollateralized();
    if (_shares > _yieldFeeTotalSupply) revert YieldFeeGTAvailable(_shares, _yieldFeeTotalSupply);

    _yieldFeeTotalSupply -= _shares;
    _mint(_recipient, _shares);

    emit MintYieldFee(msg.sender, _recipient, _shares);
  }

  /* ============ Setter Functions ============ */

  /**
   * @notice Set claimer.
   * @param claimer_ Address of the claimer
   * return address New claimer address
   */
  function setClaimer(address claimer_) external onlyOwner returns (address) {
    address _previousClaimer = _claimer;
    _setClaimer(claimer_);

    emit ClaimerSet(_previousClaimer, claimer_);
    return address(claimer_);
  }

  /**
   * @notice Set liquidationPair.
   * @dev We reset approval of the previous liquidationPair and approve max for new one.
   * @param liquidationPair_ New liquidationPair address
   * return address New liquidationPair address
   */
  function setLiquidationPair(
    LiquidationPair liquidationPair_
  ) external onlyOwner returns (address) {
    if (address(liquidationPair_) == address(0)) revert LPZeroAddress();

    IERC20 _asset = IERC20(asset());
    address _previousLiquidationPair = address(_liquidationPair);

    if (_previousLiquidationPair != address(0)) {
      _asset.safeApprove(_previousLiquidationPair, 0);
    }

    _asset.safeApprove(address(liquidationPair_), type(uint256).max);

    _liquidationPair = liquidationPair_;

    emit LiquidationPairSet(liquidationPair_);
    return address(liquidationPair_);
  }

  /**
   * @notice Set yield fee percentage.
   * @dev Yield fee is represented in 9 decimals and can't exceed `1e9`.
   * @param yieldFeePercentage_ Yield fee percentage
   * return uint256 New yield fee percentage
   */
  function setYieldFeePercentage(uint256 yieldFeePercentage_) external onlyOwner returns (uint256) {
    uint256 _previousYieldFeePercentage = _yieldFeePercentage;
    _setYieldFeePercentage(yieldFeePercentage_);

    emit YieldFeePercentageSet(_previousYieldFeePercentage, yieldFeePercentage_);
    return yieldFeePercentage_;
  }

  /**
   * @notice Set fee recipient.
   * @param yieldFeeRecipient_ Address of the fee recipient
   * return address New fee recipient address
   */
  function setYieldFeeRecipient(address yieldFeeRecipient_) external onlyOwner returns (address) {
    address _previousYieldFeeRecipient = _yieldFeeRecipient;
    _setYieldFeeRecipient(yieldFeeRecipient_);

    emit YieldFeeRecipientSet(_previousYieldFeeRecipient, yieldFeeRecipient_);
    return yieldFeeRecipient_;
  }

  /* ============ Getter Functions ============ */

  /**
   * @notice Address of the yield fee recipient.
   * @return address Yield fee recipient address
   */

  function yieldFeeRecipient() public view returns (address) {
    return _yieldFeeRecipient;
  }

  /**
   * @notice Yield fee percentage.
   * @return uint256 Yield fee percentage
   */

  function yieldFeePercentage() public view returns (uint256) {
    return _yieldFeePercentage;
  }

  /**
   * @notice Get total yield fee accrued by this Vault.
   * @dev If the vault becomes underecollateralized, this total yield fee can be used to recollateralize it.
   * @return uint256 Total accrued yield fee
   */
  function yieldFeeTotalSupply() public view returns (uint256) {
    return _yieldFeeTotalSupply;
  }

  /**
   * @notice Address of the TwabController keeping track of balances.
   * @return address TwabController address
   */
  function twabController() public view returns (address) {
    return address(_twabController);
  }

  /**
   * @notice Address of the ERC4626 vault generating yield.
   * @return address YieldVault address
   */
  function yieldVault() public view returns (address) {
    return address(_yieldVault);
  }

  /**
   * @notice Address of the LiquidationPair used to liquidate yield for prize token.
   * @return address LiquidationPair address
   */
  function liquidationPair() public view returns (address) {
    return address(_liquidationPair);
  }

  /**
   * @notice Address of the PrizePool that computes prizes.
   * @return address PrizePool address
   */
  function prizePool() public view returns (address) {
    return address(_prizePool);
  }

  /**
   * @notice Address of the claimer.
   * @return address Claimer address
   */
  function claimer() public view returns (address) {
    return address(_claimer);
  }

  /* ============ Internal Functions ============ */

  /**
   * @notice Total amount of assets managed by this Vault.
   * @dev The total amount of assets managed by this vault is equal to
   *      the amount of assets managed by the YieldVault + the amount living in this vault.
   */
  function _totalAssets() internal view returns (uint256) {
    return _yieldVault.maxWithdraw(address(this)) + super.totalAssets();
  }

  /**
   * @notice Total amount of shares minted by this Vault.
   * @return uint256 Total amount of shares
   */
  function _totalSupply() internal view returns (uint256) {
    return _twabController.totalSupply(address(this));
  }

  /**
   * @notice Total amount of shares managed by this Vault.
   * @dev Equal to the total amount of shares minted by this Vault
   *      + the total amount of yield fees allocated by this Vault.
   * @return uint256 Total amount of shares
   */
  function _totalShares() internal view returns (uint256) {
    return _totalSupply() + _yieldFeeTotalSupply;
  }

  /* ============ Liquidate Functions ============ */

  /**
   * @notice Return the yield amount (available yield minus fees) that can be liquidated by minting Vault shares.
   * @param _token Address of the token to get available balance for
   * @return uint256 Available amount of `_token`
   */
  function _liquidatableBalanceOf(address _token) internal view returns (uint256) {
    if (_token != address(this)) revert LiquidationTokenOutNotVaultShare(_token, address(this));

    uint256 _availableYield = availableYieldBalance();

    unchecked {
      return _availableYield -= _availableYieldFeeBalance(_availableYield);
    }
  }

  /**
   * @notice Available yield fee amount.
   * @param _availableYield Total amount of yield available
   * @return uint256 Available yield fee balance
   */
  function _availableYieldFeeBalance(uint256 _availableYield) internal view returns (uint256) {
    return (_availableYield * _yieldFeePercentage) / FEE_PRECISION;
  }

  /**
   * @notice Increase yield fee balance accrued by `_yieldFeeRecipient`.
   * @param _shares Amount of shares to increase yield fee balance by
   */
  function _increaseYieldFeeBalance(uint256 _shares) internal {
    _yieldFeeTotalSupply += _shares;
  }

  /* ============ Conversion Functions ============ */

  /// @inheritdoc ERC4626
  function _convertToShares(
    uint256 _assets,
    Math.Rounding _rounding
  ) internal view virtual override returns (uint256) {
    uint256 _exchangeRate = _currentExchangeRate();

    return
      (_assets == 0 || _exchangeRate == 0)
        ? _assets
        : _assets.mulDiv(_assetUnit, _exchangeRate, _rounding);
  }

  /// @inheritdoc ERC4626
  function _convertToAssets(
    uint256 _shares,
    Math.Rounding _rounding
  ) internal view virtual override returns (uint256) {
    return _convertToAssets(_shares, _currentExchangeRate(), _rounding);
  }

  /**
   * @notice Convert `_shares` to `_assets`.
   * @param _shares Amount of shares to convert
   * @param _exchangeRate Exchange rate used to convert `_shares`
   * @param _rounding Rounding mode (i.e. down or up)
   */
  function _convertToAssets(
    uint256 _shares,
    uint256 _exchangeRate,
    Math.Rounding _rounding
  ) internal view returns (uint256) {
    return
      (_shares == 0 || _exchangeRate == 0)
        ? _shares
        : _shares.mulDiv(_exchangeRate, _assetUnit, _rounding);
  }

  /* ============ Deposit Functions ============ */

  /**
   * @notice Deposit/mint common workflow.
   * @dev If there are currently some underlying assets in the vault,
   *      we only transfer the difference from the user wallet into the vault.
   *      The difference is calculated this way:
   *      - if `_vaultAssets` balance is greater than 0 and lower than `_assets`,
   *        we substract `_vaultAssets` from `_assets` and deposit `_assetsDeposit` amount into the vault
   *      - if `_vaultAssets` balance is greater than or equal to `_assets`,
   *        we know the vault has enough underlying assets to fulfill the deposit
   *        so we don't transfer any assets from the user wallet into the vault
   */
  function _deposit(
    address _caller,
    address _receiver,
    uint256 _assets,
    uint256 _shares
  ) internal virtual override {
    IERC20 _asset = IERC20(asset());
    uint256 _vaultAssets = _asset.balanceOf(address(this));

    // If _asset is ERC777, `transferFrom` can trigger a reenterancy BEFORE the transfer happens through the
    // `tokensToSend` hook. On the other hand, the `tokenReceived` hook, that is triggered after the transfer,
    // calls the vault, which is assumed not malicious.
    //
    // Conclusion: we need to do the transfer before we mint so that any reentrancy would happen before the
    // assets are transferred and before the shares are minted, which is a valid state.

    // We only need to deposit new assets if there is not enough assets in the vault to fulfill the deposit
    if (_assets > _vaultAssets) {
      uint256 _assetsDeposit;

      unchecked {
        if (_vaultAssets != 0) {
          _assetsDeposit = _assets - _vaultAssets;
        }
      }

      SafeERC20.safeTransferFrom(
        _asset,
        _caller,
        address(this),
        _assetsDeposit != 0 ? _assetsDeposit : _assets
      );
    }

    _yieldVault.deposit(_assets, address(this));
    _mint(_receiver, _shares);

    emit Deposit(_caller, _receiver, _assets, _shares);
  }

  /**
   * @notice Compute the amount of assets to deposit before minting `_shares`.
   * @param _shares Amount of shares to mint
   * @param _receiver Address of the receiver of the vault shares
   * @return uint256 Amount of assets to deposit.
   */
  function _beforeMint(uint256 _shares, address _receiver) internal view returns (uint256) {
    if (_shares > maxMint(_receiver)) revert MintGTMax(_shares, _receiver, maxMint(_receiver));
    return _convertToAssets(_shares, Math.Rounding.Up);
  }

  /**
   * @notice Deposit assets into the Vault and delegate to the sponsorship address.
   * @param _assets Amount of assets to deposit
   * @param _receiver Address of the receiver of the vault shares
   * @return uint256 Amount of shares minted to `_receiver`.
   */
  function _sponsor(uint256 _assets, address _receiver) internal returns (uint256) {
    uint256 _shares = deposit(_assets, _receiver);

    if (
      _twabController.delegateOf(address(this), _receiver) != _twabController.SPONSORSHIP_ADDRESS()
    ) {
      _twabController.sponsor(_receiver);
    }

    emit Sponsor(msg.sender, _receiver, _assets, _shares);

    return _shares;
  }

  /* ============ Withdraw Functions ============ */

  /// @dev Withdraw/redeem common workflow.
  function _withdraw(
    address _caller,
    address _receiver,
    address _owner,
    uint256 _assets,
    uint256 _shares
  ) internal virtual override {
    if (_caller != _owner) {
      _spendAllowance(_owner, _caller, _shares);
    }

    // If _asset is ERC777, `transfer` can trigger a reentrancy AFTER the transfer happens through the
    // `tokensReceived` hook. On the other hand, the `tokensToSend` hook, that is triggered before the transfer,
    // calls the vault, which is assumed not malicious.
    //
    // Conclusion: we need to do the transfer after the burn so that any reentrancy would happen after the
    // shares are burned and after the assets are transferred, which is a valid state.
    _burn(_owner, _shares);

    _yieldVault.withdraw(_assets, address(this), address(this));
    SafeERC20.safeTransfer(IERC20(asset()), _receiver, _assets);

    emit Withdraw(_caller, _receiver, _owner, _assets, _shares);
  }

  /* ============ Permit Functions ============ */

  /**
   * @notice Approve `_spender` to spend `_assets` of `_owner`'s `_asset` via signature.
   * @param _asset Address of the asset to approve
   * @param _owner Address of the owner of the asset
   * @param _spender Address of the spender of the asset
   * @param _assets Amount of assets to approve
   * @param _deadline Timestamp after which the approval is no longer valid
   * @param _v V part of the secp256k1 signature
   * @param _r R part of the secp256k1 signature
   * @param _s S part of the secp256k1 signature
   */
  function _permit(
    IERC20Permit _asset,
    address _owner,
    address _spender,
    uint256 _assets,
    uint256 _deadline,
    uint8 _v,
    bytes32 _r,
    bytes32 _s
  ) internal {
    _asset.permit(_owner, _spender, _assets, _deadline, _v, _r, _s);
  }

  /* ============ State Functions ============ */

  /// @notice Update exchange rate with the current exchange rate.
  function _updateExchangeRate() internal {
    _lastRecordedExchangeRate = _currentExchangeRate();
  }

  /**
   * @notice Creates `_shares` tokens and assigns them to `_receiver`, increasing the total supply.
   * @dev Emits a {Transfer} event with `from` set to the zero address.
   * @dev `_receiver` cannot be the zero address.
   * @dev Updates the exchange rate.
   */
  function _mint(address _receiver, uint256 _shares) internal virtual override {
    _twabController.mint(_receiver, uint96(_shares));
    _updateExchangeRate();

    emit Transfer(address(0), _receiver, _shares);
  }

  /**
   * @notice Destroys `_shares` tokens from `_owner`, reducing the total supply.
   * @dev Emits a {Transfer} event with `to` set to the zero address.
   * @dev `_owner` cannot be the zero address.
   * @dev `_owner` must have at least `_shares` tokens.
   * @dev Updates the exchange rate.
   */
  function _burn(address _owner, uint256 _shares) internal virtual override {
    _twabController.burn(_owner, uint96(_shares));
    _updateExchangeRate();

    emit Transfer(_owner, address(0), _shares);
  }

  /**
   * @notice Updates `_from` and `_to` TWAB balance for a transfer.
   * @dev `_from` cannot be the zero address.
   * @dev `_to` cannot be the zero address.
   * @dev `_from` must have a balance of at least `_shares`.
   */
  function _transfer(address _from, address _to, uint256 _shares) internal virtual override {
    _twabController.transfer(_from, _to, uint96(_shares));

    emit Transfer(_from, _to, _shares);
  }

  /**
   * @notice Calculate exchange rate between the amount of assets withdrawable from the YieldVault
   *         and the amount of shares minted by this Vault.
   * @dev We exclude the amount of yield generated by the YieldVault, so user can only withdraw their share of deposits.
   *      Except when the vault is undercollateralized, in this case, any unclaim yield fee is included in the calculation.
   * @dev We start with an exchange rate of 1 which is equal to 1 underlying asset unit.
   * @return uint256 Exchange rate
   */
  function _currentExchangeRate() internal view returns (uint256) {
    uint256 _totalSupplyAmount = _totalSupply();
    uint256 _totalSupplyToAssets = _convertToAssets(
      _totalSupplyAmount,
      _lastRecordedExchangeRate,
      Math.Rounding.Down
    );

    uint256 _withdrawableAssets = _yieldVault.maxWithdraw(address(this));

    if (_withdrawableAssets > _totalSupplyToAssets) {
      _withdrawableAssets = _withdrawableAssets - (_withdrawableAssets - _totalSupplyToAssets);
    }

    if (_totalSupplyAmount != 0 && _withdrawableAssets != 0) {
      return _withdrawableAssets.mulDiv(_assetUnit, _totalSupplyAmount, Math.Rounding.Down);
    }

    return _assetUnit;
  }

  /**
   * @notice Check if the Vault is collateralized.
   * @dev The vault is collateralized if the exchange rate is greater than or equal to 1 underlying asset unit.
   * @return bool True if the vault is collateralized, false otherwise
   */
  function _isVaultCollateralized() internal view returns (bool) {
    return _currentExchangeRate() >= _assetUnit;
  }

  /// @notice Require reverting if the vault is under-collateralized.
  function _requireVaultCollateralized() internal view {
    if (!_isVaultCollateralized()) revert VaultUnderCollateralized();
  }

  /* ============ Setter Functions ============ */

  /**
   * @notice Set claimer address.
   * @param claimer_ Address of the claimer
   */
  function _setClaimer(address claimer_) internal {
    _claimer = claimer_;
  }

  /**
   * @notice Set yield fee percentage.
   * @dev Yield fee is represented in 9 decimals and can't exceed `1e9`.
   * @param yieldFeePercentage_ Yield fee percentage
   */
  function _setYieldFeePercentage(uint256 yieldFeePercentage_) internal {
    if (yieldFeePercentage_ > FEE_PRECISION)
      revert YieldFeePercentageGTPrecision(yieldFeePercentage_, FEE_PRECISION);
    _yieldFeePercentage = yieldFeePercentage_;
  }

  /**
   * @notice Set yield fee recipient address.
   * @param yieldFeeRecipient_ Address of the fee recipient
   */
  function _setYieldFeeRecipient(address yieldFeeRecipient_) internal {
    _yieldFeeRecipient = yieldFeeRecipient_;
  }
}
