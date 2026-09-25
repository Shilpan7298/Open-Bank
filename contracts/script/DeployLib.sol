// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.35;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IdentityGate} from "../src/IdentityGate.sol";
import {CreditRegistry} from "../src/CreditRegistry.sol";
import {CollateralEscrow} from "../src/CollateralEscrow.sol";
import {StakeVault} from "../src/StakeVault.sol";
import {VouchingModule} from "../src/VouchingModule.sol";
import {RateAuction} from "../src/RateAuction.sol";
import {InsuranceBasket} from "../src/InsuranceBasket.sol";
import {ReserveVault} from "../src/ReserveVault.sol";
import {LossWaterfall} from "../src/LossWaterfall.sol";
import {ScoreOracle} from "../src/ScoreOracle.sol";
import {LoanRegistry} from "../src/LoanRegistry.sol";
import {LenderVault} from "../src/LenderVault.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockEAS} from "../src/mocks/MockEAS.sol";
import {MockSanctionsOracle} from "../src/mocks/MockSanctionsOracle.sol";

/// @notice Deploys and wires the whole Phase 1 system. Shared by script/Deploy.s.sol and the system tests so both
/// use the same wiring. `admin` must be the account making the calls (the test contract or the broadcaster);
/// `handOver` then moves every admin role to the timelock and renounces the deployer's.
library DeployLib {
    bytes32 internal constant IDENTITY_SCHEMA = keccak256("OBP.identity.v1(uint256 country)");
    bytes32 internal constant SCORE_SCHEMA = keccak256(
        "OBP.score.v1(uint256 loanId,address borrower,uint8 riskBand,uint16 pdBps,uint16 minVoucherCoverBps,uint64 expiry,bytes32 rationaleHash,bytes32 modelId)"
    );

    struct Config {
        address admin;
        address guardian;
        address rebateRecipient;
        uint256 timelockDelay;
        address[] proposers; // timelock proposers and executors
    }

    struct System {
        MockUSDC usdc;
        MockEAS eas;
        MockSanctionsOracle sanctions;
        TimelockController timelock;
        IdentityGate gate;
        CreditRegistry credit;
        CollateralEscrow escrow;
        StakeVault stakeVault;
        VouchingModule vouching;
        RateAuction auction;
        InsuranceBasket basket;
        ReserveVault reserve;
        LossWaterfall waterfall;
        ScoreOracle scoreOracle;
        LoanRegistry registry;
        LenderVault lenderVault; // band 2 vault; allocator role granted separately
    }

    function deploy(Config memory c) internal returns (System memory s) {
        s.usdc = new MockUSDC();
        s.eas = new MockEAS();
        s.sanctions = new MockSanctionsOracle();
        s.timelock = new TimelockController(c.timelockDelay, c.proposers, c.proposers, address(0));
        _deployModules(s, c);
        _deployRegistry(s, c);
        s.lenderVault = new LenderVault(
            c.admin, c.guardian, s.usdc, s.registry, s.auction, s.gate, 2, "OBP Lender Vault Band 2", "obpLV2"
        );
        _wire(s);
    }

    function _deployModules(System memory s, Config memory c) private {
        s.gate = new IdentityGate(c.admin, c.guardian, s.eas, s.sanctions, IDENTITY_SCHEMA);
        s.credit = new CreditRegistry(c.admin, c.guardian);
        s.escrow = new CollateralEscrow(c.admin, c.guardian, s.usdc);
        s.stakeVault = new StakeVault(c.admin, c.guardian, s.usdc);
        s.vouching = new VouchingModule(c.admin, c.guardian, s.stakeVault, s.gate, s.credit, 10e6);
        s.auction = new RateAuction(c.admin, c.guardian, s.usdc, s.gate);
        s.basket = new InsuranceBasket(c.admin, c.guardian, s.usdc, s.gate);
        s.reserve = new ReserveVault(c.admin, c.guardian, s.usdc, 150, 500, c.rebateRecipient);
        s.waterfall = new LossWaterfall(c.admin, c.guardian, s.escrow, s.vouching, s.basket, s.reserve);
        s.scoreOracle = new ScoreOracle(c.admin, c.guardian, s.eas, SCORE_SCHEMA, 1);
    }

    function _deployRegistry(System memory s, Config memory c) private {
        s.registry = new LoanRegistry(
            c.admin,
            c.guardian,
            LoanRegistry.Modules({
                asset: IERC20(address(s.usdc)),
                gate: s.gate,
                credit: s.credit,
                escrow: s.escrow,
                vouching: s.vouching,
                auction: s.auction,
                basket: s.basket,
                reserve: s.reserve,
                waterfall: s.waterfall,
                oracle: s.scoreOracle
            })
        );
    }

    function _wire(System memory s) private {
        address reg = address(s.registry);
        address wf = address(s.waterfall);
        s.reserve.setLoanRegistry(reg);
        s.basket.setLoanRegistry(reg);
        s.stakeVault.grantRole(s.stakeVault.DEPOSITOR_ROLE(), address(s.vouching));
        s.credit.grantRole(s.credit.REGISTRY_ROLE(), reg);
        s.escrow.grantRole(s.escrow.REGISTRY_ROLE(), reg);
        s.escrow.grantRole(s.escrow.WATERFALL_ROLE(), wf);
        s.vouching.grantRole(s.vouching.REGISTRY_ROLE(), reg);
        s.vouching.grantRole(s.vouching.WATERFALL_ROLE(), wf);
        s.auction.grantRole(s.auction.REGISTRY_ROLE(), reg);
        s.basket.grantRole(s.basket.REGISTRY_ROLE(), reg);
        s.basket.grantRole(s.basket.WATERFALL_ROLE(), wf);
        s.reserve.grantRole(s.reserve.REGISTRY_ROLE(), reg);
        s.reserve.grantRole(s.reserve.WATERFALL_ROLE(), wf);
        s.waterfall.grantRole(s.waterfall.REGISTRY_ROLE(), reg);
        s.auction.grantRole(s.auction.EXEMPT_LENDER_ROLE(), address(s.lenderVault));
    }

    /// @notice Every governed contract, for hand-over and governance tests.
    function modules(System memory s) internal pure returns (AccessControl[12] memory m) {
        m = [
            AccessControl(s.gate),
            s.credit,
            s.escrow,
            s.stakeVault,
            s.vouching,
            s.auction,
            s.basket,
            s.reserve,
            s.waterfall,
            s.scoreOracle,
            s.registry,
            s.lenderVault
        ];
    }

    /// @notice Give the timelock DEFAULT_ADMIN_ROLE everywhere and renounce `admin`'s.
    function handOver(System memory s, address admin) internal {
        AccessControl[12] memory m = modules(s);
        bytes32 adminRole = 0x00;
        for (uint256 i; i < m.length; i++) {
            m[i].grantRole(adminRole, address(s.timelock));
            m[i].renounceRole(adminRole, admin);
        }
    }
}
