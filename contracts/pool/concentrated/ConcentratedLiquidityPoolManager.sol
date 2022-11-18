// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity >=0.8.0;

import "../../abstract/Multicall.sol";
import "../../abstract/TridentERC721.sol";
import "../../interfaces/IMasterDeployer.sol";
import "../../interfaces/IBentoBoxMinimal.sol";
import "../../interfaces/ITridentRouter.sol";
import "../../interfaces/IConcentratedLiquidityPoolManager.sol";
import "../../interfaces/IConcentratedLiquidityPool.sol";
import "../../interfaces/IPositionManager.sol";
import "../../libraries/FullMath.sol";
import "../../libraries/TickMath.sol";
import "../../libraries/DyDxMath.sol";

/// @notice Trident Concentrated Liquidity Pool periphery contract that combines non-fungible position management and staking.
contract ConcentratedLiquidityPoolManager is IConcentratedLiquidityPoolManagerStruct, IPositionManager, TridentERC721, Multicall {
    event IncreaseLiquidity(address indexed pool, address indexed owner, uint256 indexed positionId, uint128 liquidity);
    event DecreaseLiquidity(address indexed pool, address indexed owner, uint256 indexed positionId, uint128 liquidity);

    address internal cachedMsgSender = address(1);
    address internal cachedPool = address(1);

    address internal immutable wETH;
    IBentoBoxMinimal public immutable bento;
    IMasterDeployer public immutable masterDeployer;

    mapping(uint256 => Position) public positions;

    constructor(address _masterDeployer, address _wETH) {
        masterDeployer = IMasterDeployer(_masterDeployer);
        IBentoBoxMinimal _bento = IBentoBoxMinimal(IMasterDeployer(_masterDeployer).bento());
        _bento.registerProtocol();
        bento = _bento;
        wETH = _wETH;
        mint(address(this));
    }

    function mint(
        IConcentratedLiquidityPool pool,
        int24 lowerOld,
        int24 lower,
        int24 upperOld,
        int24 upper,
        uint128 amount0Desired,
        uint128 amount1Desired,
        bool native,
        uint256 minLiquidity,
        uint256 positionId
    ) external payable returns (uint256 _positionId) {
        require(masterDeployer.pools(address(pool)), "INVALID_POOL");

        cachedMsgSender = msg.sender;
        cachedPool = address(pool);

        uint128 liquidityMinted = uint128(
            pool.mint(
                IConcentratedLiquidityPoolStruct.MintParams({
                    lowerOld: lowerOld,
                    lower: lower,
                    upperOld: upperOld,
                    upper: upper,
                    amount0Desired: amount0Desired,
                    amount1Desired: amount1Desired,
                    native: native
                })
            )
        );

        require(liquidityMinted >= minLiquidity, "TOO_LITTLE_RECEIVED");

        if (positionId == 0) {
            (uint256 feeGrowthInside0, uint256 feeGrowthInside1) = pool.rangeFeeGrowth(lower, upper);

            // We mint a new NFT.
            _positionId = nftCount.minted;
            positions[_positionId] = Position({
                pool: pool,
                liquidity: liquidityMinted,
                lower: lower,
                upper: upper,
                latestAddition: uint32(block.timestamp),
                feeGrowthInside0: feeGrowthInside0,
                feeGrowthInside1: feeGrowthInside1,
                unclaimedFees0: 0,
                unclaimedFees1: 0
            });
            mint(msg.sender);
        } else {
            // We increase liquidity for an existing NFT.
            _positionId = positionId;
            PositionFeesData memory positionFeesData = positionFees(_positionId);
            Position storage position = positions[_positionId];
            require(address(position.pool) == address(pool), "POOL_MIS_MATCH");
            require(position.lower == lower && position.upper == upper, "RANGE_MIS_MATCH");
            require(ownerOf(positionId) == msg.sender, "NOT_ID_OWNER");

            position.feeGrowthInside0 = positionFeesData.feeGrowthInside0;
            position.feeGrowthInside1 = positionFeesData.feeGrowthInside1;

            position.unclaimedFees0 += positionFeesData.token0amount;
            position.unclaimedFees1 += positionFeesData.token1amount;

            position.liquidity += liquidityMinted;
            // Incentives should be claimed first.
            position.latestAddition = uint32(block.timestamp);
        }

        emit IncreaseLiquidity(address(pool), msg.sender, _positionId, liquidityMinted);

        cachedMsgSender = address(1);
        cachedPool = address(1);
    }

    function mintCallback(
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1,
        bool native
    ) external override {
        require(msg.sender == cachedPool, "UNAUTHORIZED_CALLBACK");
        if (native) {
            _depositFromUserToBentoBox(token0, cachedMsgSender, msg.sender, amount0);
            _depositFromUserToBentoBox(token1, cachedMsgSender, msg.sender, amount1);
        } else {
            bento.transfer(token0, cachedMsgSender, msg.sender, amount0);
            bento.transfer(token1, cachedMsgSender, msg.sender, amount1);
        }
        cachedMsgSender = address(1);
        cachedPool = address(1);
    }

    function burn(
        uint256 tokenId,
        uint128 amount,
        address recipient,
        bool unwrapBento,
        uint256 minimumOut0,
        uint256 minimumOut1
    ) external returns (uint256 token0Amount, uint256 token1Amount) {
        require(msg.sender == ownerOf(tokenId), "NOT_ID_OWNER");

        Position memory position = positions[tokenId];

        require(position.liquidity != 0, "NO_LIQUIDITY");

        PositionFeesData memory positionFeesData = positionFees(tokenId);

        if (amount < position.liquidity) {
            (token0Amount, token1Amount, , ) = position.pool.burn(position.lower, position.upper, amount);

            positions[tokenId].feeGrowthInside0 = positionFeesData.feeGrowthInside0;
            positions[tokenId].feeGrowthInside1 = positionFeesData.feeGrowthInside1;
            positions[tokenId].liquidity -= amount;

            token0Amount += position.unclaimedFees0;
            token1Amount += position.unclaimedFees1;

            position.unclaimedFees0 = 0;
            position.unclaimedFees1 = 0;
        } else {
            amount = position.liquidity;
            (token0Amount, token1Amount, , ) = position.pool.burn(position.lower, position.upper, amount);

            token0Amount += position.unclaimedFees0;
            token1Amount += position.unclaimedFees1;

            burn(tokenId);
            delete positions[tokenId];
        }

        require(token0Amount >= minimumOut0 && token1Amount >= minimumOut1, "TOO_LITTLE_RECEIVED");

        unchecked {
            token0Amount += positionFeesData.token0amount;
            token1Amount += positionFeesData.token1amount;
        }

        _transferBoth(position.pool, recipient, token0Amount, token1Amount, unwrapBento);

        emit DecreaseLiquidity(address(position.pool), msg.sender, tokenId, amount);
    }

    function collect(
        uint256 tokenId,
        address recipient,
        bool unwrapBento
    ) public returns (uint256 token0amount, uint256 token1amount) {
        require(msg.sender == ownerOf(tokenId), "NOT_ID_OWNER");
        Position storage position = positions[tokenId];

        (, , , , , , address token0, address token1) = position.pool.getImmutables();

        PositionFeesData memory positionFeesData = positionFees(tokenId);

        token0amount = positionFeesData.token0amount + position.unclaimedFees0;
        token1amount = positionFeesData.token1amount + position.unclaimedFees1;

        position.unclaimedFees0 = 0;
        position.unclaimedFees1 = 0;

        position.feeGrowthInside0 = positionFeesData.feeGrowthInside0;
        position.feeGrowthInside1 = positionFeesData.feeGrowthInside1;

        uint256 balance0 = bento.balanceOf(token0, address(this));
        uint256 balance1 = bento.balanceOf(token1, address(this));

        if (balance0 < token0amount || balance1 < token1amount) {
            (uint256 amount0fees, uint256 amount1fees) = position.pool.collect(position.lower, position.upper);

            uint256 newBalance0 = amount0fees + balance0;
            uint256 newBalance1 = amount1fees + balance1;

            // Rounding errors due to frequent claiming of other users in the same position may cost us some wei units.
            if (token0amount > newBalance0) token0amount = newBalance0;
            if (token1amount > newBalance1) token1amount = newBalance1;
        }

        _transferOut(token0, recipient, token0amount, unwrapBento);
        _transferOut(token1, recipient, token1amount, unwrapBento);
    }

    struct PositionFeesData {
        uint256 token0amount;
        uint256 token1amount;
        uint256 feeGrowthInside0;
        uint256 feeGrowthInside1;
    }

    /// @notice Returns the claimable fees and the fee growth accumulators of a given position.
    function positionFees(uint256 tokenId) public view returns (PositionFeesData memory) {
        Position memory position = positions[tokenId];

        (uint256 feeGrowthInside0, uint256 feeGrowthInside1) = position.pool.rangeFeeGrowth(position.lower, position.upper);

        uint256 token0amount = FullMath.mulDiv(
            feeGrowthInside0 - position.feeGrowthInside0,
            position.liquidity,
            0x100000000000000000000000000000000
        );

        uint256 token1amount = FullMath.mulDiv(
            feeGrowthInside1 - position.feeGrowthInside1,
            position.liquidity,
            0x100000000000000000000000000000000
        );

        return
            PositionFeesData({
                token0amount: token0amount,
                token1amount: token1amount,
                feeGrowthInside0: feeGrowthInside0,
                feeGrowthInside1: feeGrowthInside1
            });
    }

    function _transferBoth(
        IConcentratedLiquidityPool pool,
        address to,
        uint256 token0Amount,
        uint256 token1Amount,
        bool unwrapBento
    ) internal {
        (, , , , , , address token0, address token1) = pool.getImmutables();
        _transferOut(token0, to, token0Amount, unwrapBento);
        _transferOut(token1, to, token1Amount, unwrapBento);
    }

    function _transferOut(
        address token,
        address to,
        uint256 shares,
        bool unwrapBento
    ) internal {
        if (unwrapBento) {
            bento.withdraw(token, address(this), to, 0, shares);
        } else {
            bento.transfer(token, address(this), to, shares);
        }
    }

    function _depositFromUserToBentoBox(
        address token,
        address sender,
        address recipient,
        uint256 amount
    ) internal {
        if (token == wETH && address(this).balance > 0) {
            // 'amount' is in BentoBox share units.
            uint256 ethAmount = bento.toAmount(token, amount, true);
            if (address(this).balance >= ethAmount) {
                bento.deposit{value: ethAmount}(address(0), sender, recipient, 0, amount);
                return;
            }
        }
        bento.deposit(token, sender, recipient, 0, amount);
    }
}
