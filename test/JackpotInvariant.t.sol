// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {JackpotFixture, JackpotHook, PoolKey, PoolId, Currency, IHooks} from "./fixtures/JackpotFixture.sol";
import {JackpotHandler} from "./handlers/JackpotHandler.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

contract JackpotInvariantToken is ERC20 {
    constructor() ERC20("Second pool token", "SECOND") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}

/// @notice Two real pools, one hook, three players, and an independent per-pool accounting model.
/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract JackpotInvariantTest is JackpotFixture {
    JackpotInvariantToken internal secondToken;
    PoolKey internal secondKey;
    PoolId internal secondId;
    JackpotHandler internal handler;
    address[3] internal actors = [address(0x1001), address(0x1002), address(0x1003)];

    function setUp() public override {
        super.setUp();
        secondToken = new JackpotInvariantToken();
        secondKey =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(secondToken)), 3000, 60, IHooks(address(hook)));
        secondId = secondKey.toId();
        manager.initialize(secondKey, INITIAL_PRICE);
        secondToken.approve(address(liquidity), type(uint256).max);
        liquidity.modifyLiquidity{value: 200 ether}(
            secondKey, ModifyLiquidityParams(-887220, 887220, 100_000 ether, 0), ""
        );
        handler = new JackpotHandler(hook, router, key, secondKey, actors);
        for (uint256 i; i < actors.length; ++i) {
            vm.deal(actors[i], 100_000 ether);
            assertTrue(ice.transfer(actors[i], 5_000_000 ether));
            assertTrue(secondToken.transfer(actors[i], 5_000_000 ether));
            vm.startPrank(actors[i]);
            ice.approve(address(router), type(uint256).max);
            ice.approve(address(hook), type(uint256).max);
            secondToken.approve(address(router), type(uint256).max);
            secondToken.approve(address(hook), type(uint256).max);
            vm.stopPrank();
        }

        // A live ticket of each currency in each pool prevents a run from starting with only
        // impossible draw actions. Seed exclusively through the handler so its model starts at zero.
        handler.swap(0, 0, 2, 0, true);
        handler.swap(0, 2, 2, 1, false);
        handler.swap(1, 1, 2, 2, true);
        handler.swap(1, 3, 2, 0, false);

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.swap.selector;
        selectors[1] = handler.fillTank.selector;
        selectors[2] = handler.draw.selector;
        selectors[3] = handler.advance.selector;
        selectors[4] = handler.rejectFill.selector;
        selectors[5] = handler.drawUnknown.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// The handler uses the fixture's existing roll preimage helper, without replacing hook code.
    function hashForRoll(PoolId id, uint256 ticketId, uint256 roll) external pure returns (bytes32) {
        return _hashForRoll(id, ticketId, roll);
    }

    function invariant_potsEqualFeesPlusFillsMinusPayouts() public view {
        for (uint256 p; p < 2; ++p) {
            (uint256 ethPot, uint256 tokenPot) = hook.pots(handler.ids(p));
            assertEq(ethPot, handler.expectedPot(p, 0), "native ghost conservation");
            assertEq(tokenPot, handler.expectedPot(p, 1), "token ghost conservation");
        }
        assertFalse(handler.badFunding(), "tank did not transfer exactly 10 tokens per pee");
        assertFalse(handler.badSwap(), "specified swap amount was not settled exactly");
    }

    function invariant_allPoolsShareExactlyTheirCurrencyClaims() public view {
        (uint256 firstEth, uint256 firstIce) = hook.pots(poolId);
        (uint256 secondEth, uint256 secondIce) = hook.pots(secondId);
        assertEq(manager.balanceOf(address(hook), 0), firstEth + secondEth, "shared native claims");
        assertEq(manager.balanceOf(address(hook), uint160(address(ice))), firstIce, "first token claims");
        assertEq(manager.balanceOf(address(hook), uint160(address(secondToken))), secondIce, "second token claims");
        assertEq(address(hook).balance, 0, "hook retained native currency");
        assertEq(ice.balanceOf(address(hook)), 0, "hook retained first token");
        assertEq(secondToken.balanceOf(address(hook)), 0, "hook retained second token");
    }

    function invariant_actionsCannotChangeTheOtherPool() public view {
        assertFalse(handler.badIsolation(), "other pool's pots or ticket counter changed");
    }

    function invariant_ticketsResolveOnceAndOnlyPayTheirRecordedPlayer() public view {
        assertFalse(handler.badRecipient(), "recipient, bystander, keeper, router, or manager balance mismatch");
        for (uint256 p; p < 2; ++p) {
            for (uint256 id; id < handler.expectedNext(p); ++id) {
                JackpotHandler.GhostTicket memory expected = handler.ghostTicket(p, id);
                JackpotHook.Ticket memory actual = hook.ticket(handler.ids(p), id);
                assertLe(expected.draws, 1, "ticket resolved twice");
                assertEq(actual.drawn, expected.draws == 1, "ticket drawn state");
                assertEq(actual.player, expected.player, "ticket attribution changed");
                assertEq(actual.fee, expected.fee, "ticket fee");
                assertEq(actual.blockNumber, expected.issuedAt, "ticket block");
                address token = p == 0 ? address(ice) : address(secondToken);
                assertEq(Currency.unwrap(actual.currency), expected.isEth ? address(0) : token, "ticket currency");
            }
        }
    }

    function invariant_drawPayoutsRespectBothCapsAndTheOutcomeTable() public view {
        assertFalse(handler.badPayout(), "payout exceeded jackpot or small-prize cap");
        assertFalse(handler.badEvent(), "Drawn event disagrees with independent outcome model");
        assertFalse(handler.badRecipient(), "actual transfers disagree with independent outcome model");
    }

    function invariant_expiredTicketsEmitZeroRollAndPayNothing() public view {
        assertFalse(handler.badExpiry(), "expired draw emitted a nonzero roll or paid a prize");
        assertFalse(handler.badEvent(), "draw event missing or incorrect");
    }

    function invariant_ticketCounterGrowsExactlyForQualifyingSwaps() public view {
        assertFalse(handler.badTickets(), "incorrect per-action ticket counter transition");
        for (uint256 p; p < 2; ++p) {
            assertEq(hook.nextTicketId(handler.ids(p)), handler.expectedNext(p), "modeled ticket count");
            assertEq(handler.expectedNext(p), handler.qualifyingSwaps(p), "one ticket per qualifying swap");
        }
    }

    function invariant_expectedFailuresAreAtomicAndNoUnexpectedRevertsOccur() public view {
        assertEq(handler.unexpectedReverts(), 0, "unexpected production revert (inspect lastUnexpectedRevert)");
        assertFalse(handler.badRejection(), "expected rejection succeeded or changed state");
    }

    // Deterministic handler checks guarantee the generator exercises the cases named in the task.
    // They complement random stateful sequences; no coverage assertion depends on random luck.
    function test_handlerCoversEverySwapModeThresholdAndPlayerAttribution() public {
        for (uint256 p; p < 2; ++p) {
            for (uint256 mode; mode < 4; ++mode) {
                uint256 beforeCount = handler.swapModes(p, mode);
                for (uint256 size; size < 8; ++size) {
                    for (uint256 player; player < 3; ++player) {
                        handler.swap(p, mode, size, player, true);
                        handler.swap(p, mode, size, player, false);
                    }
                }
                assertEq(handler.swapModes(p, mode) - beforeCount, 48, "successful mode coverage");
            }
            assertGe(handler.belowThresholdSwaps(p), 72);
            assertGe(handler.qualifyingSwaps(p), 120);
            assertGe(handler.attributionModes(p, 0), 96);
            assertGe(handler.attributionModes(p, 1), 96);
        }
        _assertAll();
    }

    function test_handlerDrawsAtBothValidBoundariesWithEveryOutcome() public {
        for (uint256 p; p < 2; ++p) {
            handler.fillTank(p, 999, p);
            for (uint256 ageSeed = 1; ageSeed <= 2; ++ageSeed) {
                for (uint256 rollSeed; rollSeed < 7; ++rollSeed) {
                    for (uint256 currency; currency < 2; ++currency) {
                        uint256 id = handler.expectedNext(p);
                        handler.swap(p, currency == 0 ? 0 : 2, 2, rollSeed % 3, currency == 0);
                        handler.draw(p, id, 0, rollSeed); // B+1: caught TooEarly; remains drawable.
                        handler.draw(p, id, ageSeed, rollSeed); // B+2 or B+256, then AlreadyDrawn.
                        assertTrue(hook.ticket(handler.ids(p), id).drawn);
                        _assertAll();
                    }
                }
            }
            assertEq(handler.drawAges(p, 1), 28);
            assertEq(handler.drawAges(p, 2), 14);
            assertEq(handler.drawAges(p, 256), 14);
            assertEq(handler.drawRolls(p, 77), 4);
            assertEq(handler.drawRolls(p, 13), 4);
            for (uint256 roll = 20; roll <= 100; roll += 20) {
                assertEq(handler.drawRolls(p, roll), 4);
            }
        }
        assertEq(handler.earlyRejections(), 56);
        assertEq(handler.repeatRejections(), 56);
    }

    function test_handlerExpiryIgnoresWinningHashAndNeverResurrectsTickets() public {
        for (uint256 p; p < 2; ++p) {
            handler.fillTank(p, 10, p);
            for (uint256 currency; currency < 2; ++currency) {
                uint256 id = handler.expectedNext(p);
                handler.swap(p, currency == 0 ? 0 : 2, 2, p, currency == 0);
                handler.draw(p, id, 3, 0); // B+257 with hash chosen for roll 77.
                handler.draw(p, id, 1, 0); // A used ticket rejects even when an earlier age is requested.
                assertEq(handler.ghostTicket(p, id).draws, 1);
            }
            assertEq(handler.drawRolls(p, 0), 2);
            assertEq(handler.drawAges(p, 257), 2);
        }
        uint256 beforeBlock = block.number;
        handler.advance(299);
        assertEq(block.number, beforeBlock + 300);
        handler.draw(0, 0, 0, 0); // Seeded ticket is undrawn, but its B+1 is in the past.
        assertEq(handler.skippedDraws(), 1);
        assertFalse(hook.ticket(poolId, 0).drawn);
        _assertAll();
    }

    function test_handlerRejectsUnknownTicketsAndInvalidOrUnfundedFills() public {
        for (uint256 p; p < 2; ++p) {
            handler.fillTank(p, 0, p); // Minimum one pee.
            handler.fillTank(p, 999, p); // Maximum 1000 pees.
            for (uint256 kind; kind < 4; ++kind) {
                handler.rejectFill(p, kind, kind);
            }
            handler.drawUnknown(p, 0);
            handler.drawUnknown(p, type(uint256).max);
            // A rejected approval-free fill restored approval and the next valid fill succeeds.
            handler.fillTank(p, 0, 0);
            assertEq(handler.fills(p), 3);
        }
        assertEq(handler.invalidFillRejections(), 8);
        assertEq(handler.unknownRejections(), 4);
        _assertAll();
    }

    function test_handlerSmallPrizesExerciseBothSidesOfTheMinimumInBothCurrencies() public {
        for (uint256 p; p < 2; ++p) {
            // Small seed pots make the first small prize pot-limited in each currency.
            _smallPrize(p, true, true);
            _smallPrize(p, false, true);
            // Increase ETH fees above 200 times the minimum ticket fee, and fund the token pot.
            for (uint256 i; i < 12; ++i) {
                handler.swap(p, 0, 7 + 8 * (0.02 ether - 0.001 ether), i, true);
            }
            handler.fillTank(p, 999, p);
            _smallPrize(p, true, false);
            _smallPrize(p, false, false);
        }
        _assertAll();
    }

    function test_handlerJackpotRoundsDownNonDivisiblePotsInBothPools() public {
        for (uint256 p; p < 2; ++p) {
            uint256 id = handler.expectedNext(p);
            // size bucket 5 keeps threshold fee + 1 wei, making both pots non-divisible by ten.
            handler.swap(p, 0, 5, p, true);
            handler.swap(p, 2, 5, p, false);
            (uint256 eth, uint256 token) = hook.pots(handler.ids(p));
            assertEq(eth % 10, 1);
            assertEq(token % 10, 1);
            handler.draw(p, id, 1, 0);
            assertEq(handler.ghostTicket(p, id).draws, 1);
            (uint256 ethLeft, uint256 tokenLeft) = hook.pots(handler.ids(p));
            assertEq(ethLeft, eth - eth * 90 / 100);
            assertEq(tokenLeft, token - token * 90 / 100);
            _assertAll();
        }
    }

    function _smallPrize(uint256 p, bool isEth, bool potLimited) private {
        uint256 id = handler.expectedNext(p);
        handler.swap(p, isEth ? 0 : 2, 2, p, isEth);
        (uint256 eth, uint256 token) = hook.pots(handler.ids(p));
        uint256 cap = (isEth ? eth : token) / 10;
        uint256 reward = handler.ghostTicket(p, id).fee * 20;
        if (potLimited) assertLt(cap, reward, "exercise pot-limited small prize");
        else assertGt(cap, reward, "exercise fee-limited small prize");
        handler.draw(p, id, 1, 1);
        assertEq(handler.ghostTicket(p, id).draws, 1);
        _assertAll();
    }

    function _assertAll() private view {
        invariant_potsEqualFeesPlusFillsMinusPayouts();
        invariant_allPoolsShareExactlyTheirCurrencyClaims();
        invariant_actionsCannotChangeTheOtherPool();
        invariant_ticketsResolveOnceAndOnlyPayTheirRecordedPlayer();
        invariant_drawPayoutsRespectBothCapsAndTheOutcomeTable();
        invariant_expiredTicketsEmitZeroRollAndPayNothing();
        invariant_ticketCounterGrowsExactlyForQualifyingSwaps();
        invariant_expectedFailuresAreAtomicAndNoUnexpectedRevertsOccur();
    }
}
