// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.12;

// testing libraries
import "@ds/test.sol";
import "@std/console.sol";
import {stdCheats} from "@std/stdlib.sol";
import {Vm} from "@std/Vm.sol";
import {DSTestPlus} from "@solmate/test/utils/DSTestPlus.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";

// contract dependencies
import "../external/aave/IAaveGovernanceV2.sol";
import "../external/aave/IExecutorWithTimelock.sol";
import "../ProposalPayload.sol";

contract ProposalPayloadTest is DSTestPlus, stdCheats {
    Vm private vm = Vm(HEVM_ADDRESS);

    address private aaveTokenAddress = 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9;

    address private aaveGovernanceAddress = 0xEC568fffba86c094cf06b22134B23074DFE2252c;
    address private aaveGovernanceShortExecutor = 0xEE56e2B3D491590B5b31738cC34d5232F378a8D5;

    address private llamaProposalAddress = 0x5B3bFfC0bcF8D4cAEC873fDcF719F60725767c98;

    IAaveGovernanceV2 private aaveGovernanceV2 = IAaveGovernanceV2(aaveGovernanceAddress);
    IExecutorWithTimelock private shortExecutor = IExecutorWithTimelock(aaveGovernanceShortExecutor);

    address[] private aaveWhales;

    address private proposalPayloadAddress;
    address private tokenDistributorAddress;
    address private ecosystemReserveAddress;

    address[] private targets;
    uint256[] private values;
    string[] private signatures;
    bytes[] private calldatas;
    bool[] private withDelegatecalls;
    bytes32 private ipfsHash = 0x0;

    uint256 private proposalId;

    /// @notice AaveEcosystemReserveController address.
    IEcosystemReserveController private constant reserveController =
        IEcosystemReserveController(0x3d569673dAa0575c936c7c67c4E6AedA69CC630C);

    /// @notice aUSDC token.
    ERC20 private constant aUsdc = ERC20(0xBcca60bB61934080951369a648Fb03DF4F96263C);

    /// @notice AAVE token.
    ERC20 private constant aave = ERC20(0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9);

    /// @notice Aave Grants DAO multisig address.
    address private constant aaveGrantsDaoMultisig = 0x89C51828427F70D77875C6747759fB17Ba10Ceb0;

    /// @notice Aave Ecosystem Reserve address.
    address private constant aaveEcosystemReserve = 0x25F2226B597E8F9514B3F68F00f494cF4f286491;

    /// @notice Aave Collector V2 address.
    address private constant aaveCollector = 0x464C71f6c2F760DdA6093dCB91C24c39e5d6e18c;

    // $3,000,000 / 134.28 (coingecko avg opening price from 5/4-5/10)
    uint256 private constant aaveAmount = 22341380000000000000000;
    uint256 private constant aUsdcAmount = 3000000000000;

    function setUp() public {
        // aave whales may need to be updated based on the block being used
        // these are sometimes exchange accounts or whale who move their funds

        // select large holders here: https://etherscan.io/token/0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9#balances
        aaveWhales.push(0xBE0eB53F46cd790Cd13851d5EFf43D12404d33E8);
        aaveWhales.push(0x26a78D5b6d7a7acEEDD1e6eE3229b372A624d8b7);
        aaveWhales.push(0x2FAF487A4414Fe77e2327F0bf4AE2a264a776AD2);

        // create proposal is configured to deploy a Payload contract and call execute() as a delegatecall
        // most proposals can use this format - you likely will not have to update this
        _createProposal();

        // these are generic steps for all proposals - no updates required
        _voteOnProposal();
        _skipVotingPeriod();
        _queueProposal();
        _skipQueuePeriod();
    }

    function testAaveTransfer() public {
        uint256 initialReserveBalance = 1777621264234247793724395;
        assertEq(aave.balanceOf(aaveEcosystemReserve), initialReserveBalance);

        uint256 initialMultisigBalance = 192379049942249419841;
        assertEq(aave.balanceOf(aaveGrantsDaoMultisig), initialMultisigBalance);

        _executeProposal();

        // Assert correct amount was transfered from reserve to multisig
        assertEq(aave.balanceOf(aaveEcosystemReserve), initialReserveBalance - aaveAmount);
        assertEq(aave.balanceOf(aaveGrantsDaoMultisig), initialMultisigBalance + aaveAmount);
    }

    function testAUsdcApproval() public {
        uint256 initialMultisigAllowance = 0;
        assertEq(aUsdc.allowance(aaveCollector, aaveGrantsDaoMultisig), initialMultisigAllowance);

        _executeProposal();

        // Assert correct amount was transfered from reserve to multisig
        assertEq(aUsdc.allowance(aaveCollector, aaveGrantsDaoMultisig), initialMultisigAllowance + aUsdcAmount);
    }

    function testMultisigTransferFrom() public {
        uint256 transferAmount = 15000000000;

        vm.prank(aaveGrantsDaoMultisig);
        vm.expectRevert("ERC20: transfer amount exceeds allowance");
        aUsdc.transferFrom(aaveCollector, aaveGrantsDaoMultisig, transferAmount);

        _executeProposal();

        vm.prank(aaveGrantsDaoMultisig);
        aUsdc.transferFrom(aaveCollector, aaveGrantsDaoMultisig, transferAmount);

        assertEq(aUsdc.allowance(aaveCollector, aaveGrantsDaoMultisig), aUsdcAmount - transferAmount);
        assertEq(aUsdc.balanceOf(aaveGrantsDaoMultisig), transferAmount);
    }

    function _executeProposal() public {
        // execute proposal
        aaveGovernanceV2.execute(proposalId);

        // confirm state after
        IAaveGovernanceV2.ProposalState state = aaveGovernanceV2.getProposalState(proposalId);
        assertEq(uint256(state), uint256(IAaveGovernanceV2.ProposalState.Executed), "PROPOSAL_NOT_IN_EXPECTED_STATE");
    }

    /*******************************************************************************/
    /******************     Aave Gov Process - Create Proposal     *****************/
    /*******************************************************************************/

    function _createProposal() public {
        // Uncomment to deploy new implementation contracts for testing
        // tokenDistributorAddress = deployCode("TokenDistributor.sol:TokenDistributor");
        // ecosystemReserveAddress = deployCode("AaveEcosystemReserve.sol:AaveEcosystemReserve");

        ProposalPayload proposalPayload = new ProposalPayload();
        proposalPayloadAddress = address(proposalPayload);

        bytes memory emptyBytes;

        targets.push(proposalPayloadAddress);
        values.push(0);
        signatures.push("execute()");
        calldatas.push(emptyBytes);
        withDelegatecalls.push(true);

        vm.prank(llamaProposalAddress);
        aaveGovernanceV2.create(shortExecutor, targets, values, signatures, calldatas, withDelegatecalls, ipfsHash);
        proposalId = aaveGovernanceV2.getProposalsCount() - 1;
    }

    /*******************************************************************************/
    /***************     Aave Gov Process - No Updates Required      ***************/
    /*******************************************************************************/

    function _voteOnProposal() public {
        IAaveGovernanceV2.ProposalWithoutVotes memory proposal = aaveGovernanceV2.getProposalById(proposalId);
        vm.roll(proposal.startBlock + 1);
        for (uint256 i; i < aaveWhales.length; i++) {
            vm.prank(aaveWhales[i]);
            aaveGovernanceV2.submitVote(proposalId, true);
        }
    }

    function _skipVotingPeriod() public {
        IAaveGovernanceV2.ProposalWithoutVotes memory proposal = aaveGovernanceV2.getProposalById(proposalId);
        vm.roll(proposal.endBlock + 1);
    }

    function _queueProposal() public {
        aaveGovernanceV2.queue(proposalId);
    }

    function _skipQueuePeriod() public {
        IAaveGovernanceV2.ProposalWithoutVotes memory proposal = aaveGovernanceV2.getProposalById(proposalId);
        vm.warp(proposal.executionTime + 1);
    }

    function testSetup() public {
        IAaveGovernanceV2.ProposalWithoutVotes memory proposal = aaveGovernanceV2.getProposalById(proposalId);
        assertEq(proposalPayloadAddress, proposal.targets[0], "TARGET_IS_NOT_PAYLOAD");

        IAaveGovernanceV2.ProposalState state = aaveGovernanceV2.getProposalState(proposalId);
        assertEq(uint256(state), uint256(IAaveGovernanceV2.ProposalState.Queued), "PROPOSAL_NOT_IN_EXPECTED_STATE");
    }
}
