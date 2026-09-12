// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";

contract RoyaltyRouterFactoryTest is Base {
    function test_factory_rejectsBadDao() public {
        vm.expectRevert(RoyaltyRouterFactory.BadDao.selector);
        new RoyaltyRouterFactory(bond, hook, address(pm), GOV, address(0), 1, MAX_DAO_BPS, STALE, GRACE);
        vm.expectRevert(RoyaltyRouterFactory.BadDao.selector);
        new RoyaltyRouterFactory(bond, hook, address(pm), GOV, DAO, MAX_DAO_BPS + 1, MAX_DAO_BPS, STALE, GRACE);
        vm.expectRevert(RoyaltyRouterFactory.BadDao.selector);
        new RoyaltyRouterFactory(bond, hook, address(pm), GOV, DAO, DAO_BPS, 5_001, STALE, GRACE);
    }

    function test_factory_rejectsShortPeriods() public {
        vm.expectRevert(RoyaltyRouterFactory.BadPeriods.selector);
        new RoyaltyRouterFactory(bond, hook, address(pm), GOV, DAO, DAO_BPS, MAX_DAO_BPS, 89 days, GRACE);
        vm.expectRevert(RoyaltyRouterFactory.BadPeriods.selector);
        new RoyaltyRouterFactory(bond, hook, address(pm), GOV, DAO, DAO_BPS, MAX_DAO_BPS, STALE, 6 days);
    }

    function test_governance_onlyGovSetsFee() public {
        vm.expectRevert(RoyaltyRouterFactory.NotGovernance.selector);
        factory.setFee(DAO, 1);
        vm.prank(GOV);
        vm.expectRevert(RoyaltyRouterFactory.BadDao.selector);
        factory.setFee(DAO, MAX_DAO_BPS + 1);
        vm.prank(GOV);
        factory.setFee(DAO, MAX_DAO_BPS);
        (address d, uint16 b) = factory.feeInfo();
        assertEq(d, DAO);
        assertEq(b, MAX_DAO_BPS);
    }

    function test_governance_renounceFreezesFee() public {
        vm.prank(GOV);
        factory.setGovernance(address(0));
        vm.prank(GOV);
        vm.expectRevert(RoyaltyRouterFactory.NotGovernance.selector);
        factory.setFee(DAO, 1);
        assertEq(factory.governance(), address(0));
    }

    function test_governance_handover() public {
        vm.prank(GOV);
        factory.setGovernance(KEEPER);
        vm.prank(KEEPER);
        factory.setFee(DAO, 1);
        (, uint16 b) = factory.feeInfo();
        assertEq(b, 1);
    }

    /// The factory's whole mutable surface: launch, setFee, setGovernance. Nothing else answers.
    function test_noOtherEntry() public {
        string[4] memory sigs = ["setup((address,(address,address,uint24,int24,address),address,uint16,uint256,uint64))", "setRecipient(bytes32,address)", "withdraw(address)", "updateBondCreator(address,address)"];
        for (uint256 i; i < sigs.length; i++) {
            (bool ok,) = address(factory).call(abi.encodeWithSignature(sigs[i], address(this), 1));
            assertFalse(ok, sigs[i]);
        }
    }
}
