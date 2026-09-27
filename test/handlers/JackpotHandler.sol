// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/IERC6093.sol";
import {JackpotHook} from "../../src/JackpotHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

interface IJackpotRollSource {
    function hashForRoll(PoolId id, uint256 ticketId, uint256 roll) external pure returns (bytes32);
}

/// @notice Independent accounting model. Only the six action selectors are invariant targets.
/// @dev No assertions in actions: a reverted assertion would discard the failing transition when
/// fail_on_revert is false. Instead, sticky flags preserve failures for the invariants. Unexpected
/// production reverts are caught and recorded, never treated as successful coverage.
contract JackpotHandler is Test {
    struct Ledger {
        uint256 fees;
        uint256 fills;
        uint256 payouts;
    }

    struct GhostTicket {
        address player;
        bool isEth;
        uint256 fee;
        uint256 issuedAt;
        uint256 draws;
    }

    struct SwapInput {
        uint256 pool;
        uint256 mode;
        bool isEth;
        bool exactIn;
        bool zeroForOne;
        address player;
        address payer;
        uint256 amount;
    }

    struct DrawExpectation {
        uint256 pool;
        uint256 ticketId;
        uint256 roll;
        uint256 eth;
        uint256 ice;
        uint256 preEth;
        uint256 preIce;
        bool expired;
    }

    JackpotHook public immutable hook;
    IPoolManager public immutable manager;
    PoolSwapTest public immutable router;
    IJackpotRollSource private immutable rollSource;
    PoolKey[2] private keys;
    PoolId[2] public ids;
    IERC20[2] public tokens;
    address[3] public players;
    address public constant KEEPER = address(0xD00D);

    // Currency index 0 is native ETH, index 1 is the particular pool's ERC-20.
    mapping(uint256 => mapping(uint256 => Ledger)) public ledger;
    mapping(uint256 => mapping(uint256 => GhostTicket)) public tickets;
    uint256[2] public expectedNext;

    bool public badIsolation;
    bool public badTickets;
    bool public badRecipient;
    bool public badPayout;
    bool public badExpiry;
    bool public badEvent;
    bool public badRejection;
    bool public badSwap;
    bool public badFunding;
    uint256 public unexpectedReverts;
    bytes public lastUnexpectedRevert;

    mapping(uint256 => mapping(uint256 => uint256)) public swapModes;
    mapping(uint256 => mapping(uint256 => uint256)) public attributionModes;
    mapping(uint256 => mapping(uint256 => uint256)) public drawAges;
    mapping(uint256 => mapping(uint256 => uint256)) public drawRolls;
    uint256[2] public qualifyingSwaps;
    uint256[2] public belowThresholdSwaps;
    uint256[2] public fills;
    uint256 public earlyRejections;
    uint256 public repeatRejections;
    uint256 public unknownRejections;
    uint256 public invalidFillRejections;
    uint256 public skippedDraws;
    uint256 public advances;

    bytes32 private constant DRAWN = keccak256("Drawn(bytes32,uint256,address,uint256,uint256,uint256)");

    constructor(
        JackpotHook hook_,
        PoolSwapTest router_,
        PoolKey memory first,
        PoolKey memory second,
        address[3] memory players_
    ) {
        hook = hook_;
        manager = hook_.poolManager();
        router = router_;
        rollSource = IJackpotRollSource(msg.sender);
        keys[0] = first;
        keys[1] = second;
        ids[0] = first.toId();
        ids[1] = second.toId();
        tokens[0] = IERC20(Currency.unwrap(first.currency1));
        tokens[1] = IERC20(Currency.unwrap(second.currency1));
        players = players_;
    }

    /// mode: 0 = ETH exact-in, 1 = token exact-out, 2 = token exact-in, 3 = ETH exact-out.
    /// size: dust, below/exact/above threshold, rounding edges, random below, random above.
    function swap(uint256 poolSeed, uint256 modeSeed, uint256 sizeSeed, uint256 playerSeed, bool useHookData) external {
        SwapInput memory s;
        s.pool = poolSeed % 2;
        s.mode = modeSeed % 4;
        s.zeroForOne = s.mode < 2;
        s.exactIn = s.mode % 2 == 0;
        s.isEth = s.zeroForOne == s.exactIn;
        s.player = players[playerSeed % 3];
        s.payer = players[(playerSeed % 3 + 1) % 3];
        s.amount = swapSize(s.isEth, sizeSeed);
        bytes32 otherBefore = _poolHash(1 - s.pool);
        uint256 nextBefore = hook.nextTicketId(ids[s.pool]);
        uint256 balanceBefore = s.isEth ? s.payer.balance : tokens[s.pool].balanceOf(s.payer);
        int256 specified = s.exactIn ? -int256(s.amount) : int256(s.amount);
        SwapParams memory params = SwapParams(
            s.zeroForOne, specified, s.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        // The payer differs from the player. In explicit-data mode the origin also differs, so a
        // bug substituting msg.sender or tx.origin for the encoded player cannot pass unnoticed.
        vm.prank(s.payer, useHookData ? s.payer : s.player);
        try router.swap{value: s.zeroForOne ? 1 ether : 0}(
            keys[s.pool],
            params,
            PoolSwapTest.TestSettings(false, false),
            useHookData ? abi.encode(s.player) : bytes("")
        ) returns (
            BalanceDelta delta
        ) {
            _recordSwap(s, delta, nextBefore, balanceBefore, useHookData);
        } catch (bytes memory reason) {
            _unexpected(reason);
        }
        _checkIsolation(s.pool, otherBefore);
    }

    function swapSize(bool isEth, uint256 seed) public pure returns (uint256) {
        uint256 threshold = isEth ? 0.001 ether : 100 ether;
        uint256 minimum = isEth ? 99 : 1e12;
        uint256 bucket = seed % 8;
        if (bucket == 0) return minimum;
        if (bucket == 1) return threshold - 1;
        if (bucket == 2) return threshold;
        if (bucket == 3) return threshold + 1;
        if (bucket == 4) return threshold + 99;
        if (bucket == 5) return threshold + 100;
        if (bucket == 6) return minimum + (seed / 8) % (threshold - minimum);
        uint256 maximum = isEth ? 0.02 ether : 2000 ether;
        return threshold + (seed / 8) % (maximum - threshold + 1);
    }

    function _recordSwap(
        SwapInput memory s,
        BalanceDelta delta,
        uint256 nextBefore,
        uint256 balanceBefore,
        bool useHookData
    ) private {
        uint256 fee = s.amount / 100;
        ledger[s.pool][s.isEth ? 0 : 1].fees += fee;
        bool qualifies = fee >= (s.isEth ? 0.00001 ether : 1 ether);
        if (qualifies) {
            uint256 id = expectedNext[s.pool]++;
            tickets[s.pool][id] = GhostTicket(s.player, s.isEth, fee, block.number, 0);
            qualifyingSwaps[s.pool]++;
        } else {
            belowThresholdSwaps[s.pool]++;
        }
        if (hook.nextTicketId(ids[s.pool]) != nextBefore + (qualifies ? 1 : 0)) badTickets = true;
        int256 specified = s.exactIn ? -int256(s.amount) : int256(s.amount);
        if (int256(s.isEth ? delta.amount0() : delta.amount1()) != specified) badSwap = true;
        uint256 afterBalance = s.isEth ? s.payer.balance : tokens[s.pool].balanceOf(s.payer);
        if (s.exactIn) {
            if (afterBalance + s.amount != balanceBefore) badSwap = true;
        } else if (afterBalance != balanceBefore + s.amount) {
            badSwap = true;
        }
        swapModes[s.pool][s.mode]++;
        attributionModes[s.pool][useHookData ? 1 : 0]++;
    }

    function fillTank(uint256 poolSeed, uint256 peesSeed, uint256 playerSeed) external {
        uint256 p = poolSeed % 2;
        uint256 pees = peesSeed % 1000 + 1;
        address payer = players[playerSeed % 3];
        bytes32 otherBefore = _poolHash(1 - p);
        uint256 nextBefore = hook.nextTicketId(ids[p]);
        uint256 payerBefore = tokens[p].balanceOf(payer);
        uint256 managerBefore = tokens[p].balanceOf(address(manager));
        vm.prank(payer);
        try hook.fillTank(keys[p], pees) {
            uint256 amount = pees * 10 ether;
            ledger[p][1].fills += amount;
            fills[p]++;
            if (tokens[p].balanceOf(payer) + amount != payerBefore) badFunding = true;
            if (tokens[p].balanceOf(address(manager)) != managerBefore + amount) badFunding = true;
        } catch (bytes memory reason) {
            _unexpected(reason);
        }
        if (hook.nextTicketId(ids[p]) != nextBefore) badTickets = true;
        _checkIsolation(p, otherBefore);
    }

    /// Includes both invalid bounds and a settlement failure after the hook tentatively updates its pot.
    function rejectFill(uint256 poolSeed, uint256 kindSeed, uint256 playerSeed) external {
        uint256 p = poolSeed % 2;
        uint256 kind = kindSeed % 4;
        address payer = players[playerSeed % 3];
        if (kind == 3) {
            vm.prank(payer);
            tokens[p].approve(address(hook), 0);
        }
        bytes32 beforeState = _stateHash();
        uint256[3][7] memory beforeBalances = _balances();
        bytes32 otherBefore = _poolHash(1 - p);
        uint256 pees = kind == 0 ? 0 : kind == 1 ? 1001 : kind == 2 ? type(uint256).max : 1;
        vm.prank(payer);
        try hook.fillTank(keys[p], pees) {
            badRejection = true;
        } catch (bytes memory reason) {
            bytes memory expected = kind == 3
                ? abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(hook), 0, 10 ether)
                : abi.encodeWithSelector(JackpotHook.InvalidPees.selector);
            if (keccak256(reason) != keccak256(expected)) _unexpected(reason);
            else invalidFillRejections++;
        }
        if (_stateHash() != beforeState || keccak256(abi.encode(_balances())) != keccak256(abi.encode(beforeBalances)))
        {
            badRejection = true;
        }
        if (kind == 3) {
            vm.prank(payer);
            tokens[p].approve(address(hook), type(uint256).max);
        }
        _checkIsolation(p, otherBefore);
    }

    /// Ages are exact: never roll backwards to resurrect a ticket. Impossible past ages are skipped.
    /// rollSeed maps to 77, 20, 40, 60, 80, 100, or a loser (13).
    function draw(uint256 poolSeed, uint256 ticketSeed, uint256 ageSeed, uint256 rollSeed) external {
        uint256 p = poolSeed % 2;
        if (expectedNext[p] == 0) {
            _expectDrawRevert(p, 0, JackpotHook.UnknownTicket.selector);
            return;
        }
        uint256 id = ticketSeed % expectedNext[p];
        GhostTicket storage entry = tickets[p][id];
        if (entry.draws != 0) {
            _expectDrawRevert(p, id, JackpotHook.AlreadyDrawn.selector);
            return;
        }
        uint256[4] memory ages = [uint256(1), 2, 256, 257];
        uint256 age = ages[ageSeed % 4];
        uint256 targetBlock = entry.issuedAt + age;
        if (targetBlock < block.number) {
            skippedDraws++;
            return;
        }
        vm.roll(targetBlock);
        if (age == 1) {
            _expectDrawRevert(p, id, JackpotHook.TooEarly.selector);
            drawAges[p][age]++;
            return;
        }
        uint256 kind = rollSeed % 7;
        uint256 forcedRoll = kind == 0 ? 77 : kind == 6 ? 13 : kind * 20;
        // Even at B+257, B+1 is within the blockhash window. Force a winning hash there too:
        // expiry must be based on the ticket age, not on whether blockhash returns zero.
        vm.setBlockhash(entry.issuedAt + 1, rollSource.hashForRoll(ids[p], id, forcedRoll));
        _draw(p, id, age == 257 ? 0 : forcedRoll, age == 257);
        drawAges[p][age]++;
    }

    function drawUnknown(uint256 poolSeed, uint256 ticketSeed) external {
        uint256 p = poolSeed % 2;
        _expectDrawRevert(p, expectedNext[p] + ticketSeed % 1000, JackpotHook.UnknownTicket.selector);
    }

    function advance(uint256 seed) external {
        bytes32 beforeState = _stateHash();
        vm.roll(block.number + seed % 300 + 1);
        advances++;
        if (_stateHash() != beforeState) badIsolation = true;
    }

    function _draw(uint256 p, uint256 id, uint256 roll, bool expired) private {
        DrawExpectation memory e = _expectedDraw(p, id, roll, expired);
        bytes32 otherBefore = _poolHash(1 - p);
        uint256 nextBefore = hook.nextTicketId(ids[p]);
        uint256[3][7] memory beforeBalances = _balances();
        vm.recordLogs();
        vm.prank(KEEPER, KEEPER);
        try hook.draw(ids[p], id) {
            tickets[p][id].draws++;
            ledger[p][0].payouts += e.eth;
            ledger[p][1].payouts += e.ice;
            drawRolls[p][roll]++;
            _checkDraw(e, beforeBalances, vm.getRecordedLogs());
            // Retry in every outcome, including loss and expiry. Failure must be atomic.
            _expectDrawRevert(p, id, JackpotHook.AlreadyDrawn.selector);
        } catch (bytes memory reason) {
            vm.getRecordedLogs();
            _unexpected(reason);
        }
        if (hook.nextTicketId(ids[p]) != nextBefore) badTickets = true;
        _checkIsolation(p, otherBefore);
    }

    function _expectedDraw(uint256 p, uint256 id, uint256 roll, bool expired)
        private
        view
        returns (DrawExpectation memory e)
    {
        e.pool = p;
        e.ticketId = id;
        e.roll = roll;
        e.expired = expired;
        (e.preEth, e.preIce) = hook.pots(ids[p]);
        // Compute from the ghost balance, not the hook's observed balance or its emitted payout.
        uint256 eth = expectedPot(p, 0);
        uint256 ice = expectedPot(p, 1);
        if (roll == 77) {
            e.eth = eth * 90 / 100;
            e.ice = ice * 90 / 100;
        } else if (roll == 20 || roll == 40 || roll == 60 || roll == 80 || roll == 100) {
            GhostTicket storage entry = tickets[p][id];
            uint256 cap = (entry.isEth ? eth : ice) / 10;
            uint256 prize = entry.fee * 20;
            if (prize > cap) prize = cap;
            if (entry.isEth) e.eth = prize;
            else e.ice = prize;
        }
    }

    function _checkDraw(DrawExpectation memory e, uint256[3][7] memory beforeBalances, Vm.Log[] memory logs) private {
        address recipient = tickets[e.pool][e.ticketId].player;
        uint256[3][7] memory afterBalances = _balances();
        for (uint256 a; a < 7; ++a) {
            for (uint256 c; c < 3; ++c) {
                uint256 payout = c == 0 ? e.eth : c == e.pool + 1 ? e.ice : 0;
                // The manager loses exactly the prize; only the recorded player receives it.
                if (a == 6) {
                    if (afterBalances[a][c] + payout != beforeBalances[a][c]) badRecipient = true;
                } else {
                    uint256 gain = _account(a) == recipient ? payout : 0;
                    if (afterBalances[a][c] != beforeBalances[a][c] + gain) badRecipient = true;
                }
            }
        }
        uint256 eventCount;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];
            if (log.emitter != address(hook) || log.topics.length == 0 || log.topics[0] != DRAWN) continue;
            eventCount++;
            if (log.topics.length != 4 || log.data.length != 96) {
                badEvent = true;
                continue;
            }
            if (
                log.topics[1] != PoolId.unwrap(ids[e.pool]) || uint256(log.topics[2]) != e.ticketId
                    || log.topics[3] != bytes32(uint256(uint160(recipient)))
            ) badEvent = true;
            (uint256 roll, uint256 eth, uint256 ice) = abi.decode(log.data, (uint256, uint256, uint256));
            if (roll != e.roll || eth != e.eth || ice != e.ice) badEvent = true;
            if (eth > e.preEth * 90 / 100 || ice > e.preIce * 90 / 100) badPayout = true;
            if (e.roll != 0 && e.roll % 20 == 0) {
                GhostTicket storage entry = tickets[e.pool][e.ticketId];
                uint256 cap = (entry.isEth ? e.preEth : e.preIce) / 10;
                uint256 reward = entry.fee * 20;
                if (reward < cap) cap = reward;
                if (entry.isEth ? (eth > cap || ice != 0) : (ice > cap || eth != 0)) badPayout = true;
            }
            if (e.expired && (roll != 0 || eth != 0 || ice != 0)) badExpiry = true;
        }
        if (eventCount != 1) badEvent = true;
        if (e.expired && keccak256(abi.encode(beforeBalances)) != keccak256(abi.encode(afterBalances))) {
            badExpiry = true;
        }
        // Bound actual pot outflow too, independently of what the event claims was paid.
        (uint256 ethAfter, uint256 iceAfter) = hook.pots(ids[e.pool]);
        if (ethAfter > e.preEth || iceAfter > e.preIce) {
            badPayout = true;
        } else if (e.preEth - ethAfter > e.preEth * 90 / 100 || e.preIce - iceAfter > e.preIce * 90 / 100) {
            badPayout = true;
        }
    }

    function _expectDrawRevert(uint256 p, uint256 id, bytes4 selector) private {
        bytes32 beforeState = _stateHash();
        bytes32 otherBefore = _poolHash(1 - p);
        bytes32 beforeBalances = keccak256(abi.encode(_balances()));
        bytes32 ticketBefore;
        bool exists = id < hook.nextTicketId(ids[p]);
        if (exists) ticketBefore = keccak256(abi.encode(hook.ticket(ids[p], id)));
        vm.prank(KEEPER, KEEPER);
        try hook.draw(ids[p], id) {
            badRejection = true;
        } catch (bytes memory reason) {
            if (keccak256(reason) != keccak256(abi.encodeWithSelector(selector))) _unexpected(reason);
            else if (selector == JackpotHook.TooEarly.selector) earlyRejections++;
            else if (selector == JackpotHook.AlreadyDrawn.selector) repeatRejections++;
            else unknownRejections++;
        }
        if (_stateHash() != beforeState || keccak256(abi.encode(_balances())) != beforeBalances) badRejection = true;
        if (exists && keccak256(abi.encode(hook.ticket(ids[p], id))) != ticketBefore) badRejection = true;
        _checkIsolation(p, otherBefore);
    }

    function expectedPot(uint256 p, uint256 c) public view returns (uint256) {
        Ledger memory l = ledger[p][c];
        return l.fees + l.fills - l.payouts;
    }

    function ghostTicket(uint256 p, uint256 id) external view returns (GhostTicket memory) {
        return tickets[p][id];
    }

    function _unexpected(bytes memory reason) private {
        unexpectedReverts++;
        lastUnexpectedRevert = reason;
    }

    function _checkIsolation(uint256 p, bytes32 beforeOther) private {
        if (_poolHash(1 - p) != beforeOther) badIsolation = true;
    }

    function _poolHash(uint256 p) private view returns (bytes32) {
        (uint256 eth, uint256 ice) = hook.pots(ids[p]);
        return keccak256(abi.encode(eth, ice, hook.nextTicketId(ids[p])));
    }

    function _stateHash() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                _poolHash(0),
                _poolHash(1),
                manager.balanceOf(address(hook), 0),
                manager.balanceOf(address(hook), uint160(address(tokens[0]))),
                manager.balanceOf(address(hook), uint160(address(tokens[1]))),
                address(hook).balance,
                tokens[0].balanceOf(address(hook)),
                tokens[1].balanceOf(address(hook))
            )
        );
    }

    function _account(uint256 i) private view returns (address) {
        if (i < 3) return players[i];
        if (i == 3) return KEEPER;
        if (i == 4) return address(this);
        if (i == 5) return address(router);
        return address(manager);
    }

    function _balances() private view returns (uint256[3][7] memory balances) {
        for (uint256 a; a < 7; ++a) {
            address account = _account(a);
            balances[a][0] = account.balance;
            balances[a][1] = tokens[0].balanceOf(account);
            balances[a][2] = tokens[1].balanceOf(account);
        }
    }

    receive() external payable {}
}
