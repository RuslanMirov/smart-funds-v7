pragma solidity ^0.6.12;

import "../../zeppelin-solidity/contracts/access/Ownable.sol";

/*
  The contract determines which addresses are permitted
*/
contract PermittedAddresses is Ownable {
  event AddNewPermittedAddress(address newAddress, string addressType);
  event RemovePermittedAddress(address Address);

  // Mapping to permitted addresses
  mapping (address => bool) public permittedAddresses;
  mapping (address => string) public addressesTypes;

  /**
  * @dev contructor
  *
  * @param _exchangePortal      Exchange portal contract
  * @param _poolPortal          Pool portal contract
  * @param _stableCoin          Stable coins addresses to permitted
  * @param _defiPortal          Defi portal
  */
  constructor(
    address _exchangePortal,
    address _poolPortal,
    address _stableCoin,
    address _defiPortal
  ) public
  {
    _enableAddress(_exchangePortal, "EXCHANGE_PORTAL");
    _enableAddress(_poolPortal, "POOL_PORTAL");
    _enableAddress(_stableCoin, "STABLE_COIN");
    _enableAddress(_defiPortal, "DEFI_PORTAL");
  }


  /**
  * @dev Completes the process of adding a new address to permittedAddresses
  *
  * @param _newAddress    The new address to permit
  */
  function addNewAddress(address _newAddress, string memory addressType) public onlyOwner {
    _enableAddress(_newAddress, addressType);
  }

  /**
  * @dev Disables an address, meaning SmartFunds will no longer be able to connect to them
  * if they're not already connected
  *
  * @param _address    The address to disable
  */
  function disableAddress(address _address) public onlyOwner {
    permittedAddresses[_address] = false;
    emit RemovePermittedAddress(_address);
  }

  /**
  * @dev Enables/disables an address
  *
  * @param _newAddress    The new address to set
  * @param addressType    Address type
  */
  function _enableAddress(address _newAddress, string memory addressType) private {
    permittedAddresses[_newAddress] = true;
    addressesTypes[_newAddress] = addressType;

    emit AddNewPermittedAddress(_newAddress, addressType);
  }
}
