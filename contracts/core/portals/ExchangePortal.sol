pragma solidity ^0.6.12;

/*
* This contract do swap for ERC20 via 1inch, and (between synth assest),
  Also Borrow and Reedem via Compound

  Also this contract allow get ratio between crypto curency assets
  Also get ratio for Bancor and Uniswap pools, Syntetix and Compound assets
*/

import "../../zeppelin-solidity/contracts/access/Ownable.sol";
import "../../zeppelin-solidity/contracts/math/SafeMath.sol";

import "../../bancor/interfaces/IGetBancorData.sol";
import "../../bancor/interfaces/BancorNetworkInterface.sol";

import "../../oneInch/IOneSplitAudit.sol";

import "../../compound/CEther.sol";
import "../../compound/CToken.sol";

import "../interfaces/ExchangePortalInterface.sol";
import "../interfaces/PermittedStablesInterface.sol";
import "../interfaces/PoolPortalInterface.sol";
import "../interfaces/ITokensTypeStorage.sol";
import "../interfaces/IMerkleTreeTokensVerification.sol";


contract ExchangePortal is ExchangePortalInterface, Ownable {
  using SafeMath for uint256;

  uint public version = 4;

  // Contract for handle tokens types
  ITokensTypeStorage public tokensTypes;

  // Contract for merkle tree white list verification
  IMerkleTreeTokensVerification public merkleTreeWhiteList;

  // COMPOUND
  CEther public cEther;

  // 1INCH
  IOneSplitAudit public oneInch;

  // BANCOR
  IGetBancorData public bancorData;

  // CoTrader additional
  PoolPortalInterface public poolPortal;

  // 1 inch flags
  // By default support Bancor + Uniswap + Uniswap v2
  uint256 oneInchFlags = 570425349;

  // Enum
  // NOTE: You can add a new type at the end, but DO NOT CHANGE this order,
  // because order has dependency in other contracts like ConvertPortal
  enum ExchangeType { Paraswap, Bancor, OneInch }

  // This contract recognizes ETH by this address
  IERC20 constant private ETH_TOKEN_ADDRESS = IERC20(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

  // Trade event
  event Trade(
     address trader,
     address src,
     uint256 srcAmount,
     address dest,
     uint256 destReceived,
     uint8 exchangeType
  );

  // black list for non trade able tokens
  mapping (address => bool) disabledTokens;

  // Modifier to check that trading this token is not disabled
  modifier tokenEnabled(IERC20 _token) {
    require(!disabledTokens[address(_token)]);
    _;
  }

  /**
  * @dev contructor
  *
  * @param _bancorData             address of GetBancorData helper
  * @param _poolPortal             address of pool portal
  * @param _oneInch                address of 1inch OneSplitAudit contract
  * @param _cEther                 address of the COMPOUND cEther
  * @param _tokensTypes            address of the ITokensTypeStorage
  * @param _merkleTreeWhiteList    address of the IMerkleTreeWhiteList
  */
  constructor(
    address _bancorData,
    address _poolPortal,
    address _oneInch,
    address _cEther,
    address _tokensTypes,
    address _merkleTreeWhiteList
    )
    public
  {
    bancorData = IGetBancorData(_bancorData);
    poolPortal = PoolPortalInterface(_poolPortal);
    oneInch = IOneSplitAudit(_oneInch);
    cEther = CEther(_cEther);
    tokensTypes = ITokensTypeStorage(_tokensTypes);
    merkleTreeWhiteList = IMerkleTreeTokensVerification(_merkleTreeWhiteList);
  }


  // EXCHANGE Functions

  /**
  * @dev Facilitates a trade for a SmartFund
  *
  * @param _source            ERC20 token to convert from
  * @param _sourceAmount      Amount to convert from (in _source token)
  * @param _destination       ERC20 token to convert to
  * @param _type              The type of exchange to trade with
  * @param _proof             Merkle tree proof (if not used just set [])
  * @param _positions         Merkle tree positions (if not used just set [])
  * @param _additionalData    For additional data (if not used just set 0x0)
  * @param _verifyDestanation For additional check if token in list or not
  *
  * @return receivedAmount    The amount of _destination received from the trade
  */
  function trade(
    IERC20 _source,
    uint256 _sourceAmount,
    IERC20 _destination,
    uint256 _type,
    bytes32[] calldata _proof,
    uint256[] calldata _positions,
    bytes calldata _additionalData,
    bool _verifyDestanation
  )
    external
    override
    payable
    tokenEnabled(_destination)
    returns (uint256 receivedAmount)
  {
    // throw if destanation token not in white list
    if(_verifyDestanation)
      _verifyToken(address(_destination), _proof, _positions);

    require(_source != _destination, "source can not be destination");

    // check ETH payable case
    if (_source == ETH_TOKEN_ADDRESS) {
      require(msg.value == _sourceAmount);
    } else {
      require(msg.value == 0);
    }

    // SHOULD TRADE PARASWAP HERE
    if (_type == uint(ExchangeType.Paraswap)) {
      revert("PARASWAP not supported");
    }
    // SHOULD TRADE BANCOR HERE
    else if (_type == uint(ExchangeType.Bancor)){
      receivedAmount = _tradeViaBancorNewtork(
          address(_source),
          address(_destination),
          _sourceAmount
      );
    }
    // SHOULD TRADE 1INCH HERE
    else if (_type == uint(ExchangeType.OneInch)){
      receivedAmount = _tradeViaOneInch(
          address(_source),
          address(_destination),
          _sourceAmount,
          _additionalData
      );
    }

    else {
      // unknown exchange type
      revert();
    }

    // Additional check
    require(receivedAmount > 0, "received amount can not be zerro");

    // Send destination
    if (_destination == ETH_TOKEN_ADDRESS) {
      (msg.sender).transfer(receivedAmount);
    } else {
      // transfer tokens received to sender
      _destination.transfer(msg.sender, receivedAmount);
    }

    // Send remains
    _sendRemains(_source, msg.sender);

    // Trigger event
    emit Trade(
      msg.sender,
      address(_source),
      _sourceAmount,
      address(_destination),
      receivedAmount,
      uint8(_type)
    );
  }

  // Facilitates for send source remains
  function _sendRemains(IERC20 _source, address _receiver) private {
    // After the trade, any _source that exchangePortal holds will be sent back to msg.sender
    uint256 endAmount = (_source == ETH_TOKEN_ADDRESS)
    ? address(this).balance
    : _source.balanceOf(address(this));

    // Check if we hold a positive amount of _source
    if (endAmount > 0) {
      if (_source == ETH_TOKEN_ADDRESS) {
        payable(_receiver).transfer(endAmount);
      } else {
        _source.transfer(_receiver, endAmount);
      }
    }
  }


  // Facilitates for verify destanation token input (check if token in merkle list or not)
  // revert transaction if token not in list
  function _verifyToken(
    address _destination,
    bytes32 [] memory proof,
    uint256 [] memory positions)
    private
    view
  {
    bool status = merkleTreeWhiteList.verify(_destination, proof, positions);

    if(!status)
      revert("Dest not in white list");
  }

 // Facilitates trade with 1inch
 function _tradeViaOneInch(
   address sourceToken,
   address destinationToken,
   uint256 sourceAmount,
   bytes memory _additionalData
   )
   private
   returns(uint256 destinationReceived)
 {
    (uint256 flags,
     uint256[] memory _distribution) = abi.decode(_additionalData, (uint256, uint256[]));

    if(IERC20(sourceToken) == ETH_TOKEN_ADDRESS) {
      oneInch.swap.value(sourceAmount)(
        IERC20(sourceToken),
        IERC20(destinationToken),
        sourceAmount,
        1,
        _distribution,
        flags
        );
    } else {
      _transferFromSenderAndApproveTo(IERC20(sourceToken), sourceAmount, address(oneInch));
      oneInch.swap(
        IERC20(sourceToken),
        IERC20(destinationToken),
        sourceAmount,
        1,
        _distribution,
        flags
        );
    }

    destinationReceived = tokenBalance(IERC20(destinationToken));
    setTokenType(destinationToken, "CRYPTOCURRENCY");
 }


 // Facilitates trade with Bancor
 function _tradeViaBancorNewtork(
   address sourceToken,
   address destinationToken,
   uint256 sourceAmount
   )
   private
   returns(uint256 returnAmount)
 {
    // get latest bancor contracts
    BancorNetworkInterface bancorNetwork = BancorNetworkInterface(
      bancorData.getBancorContractAddresByName("BancorNetwork")
    );

    // Get Bancor tokens path
    address[] memory path = bancorData.getBancorPathForAssets(IERC20(sourceToken), IERC20(destinationToken));

    // Convert addresses to ERC20
    IERC20[] memory pathInERC20 = new IERC20[](path.length);
    for(uint i=0; i<path.length; i++){
        pathInERC20[i] = IERC20(path[i]);
    }

    // trade
    if (IERC20(sourceToken) == ETH_TOKEN_ADDRESS) {
      returnAmount = bancorNetwork.convert.value(sourceAmount)(pathInERC20, sourceAmount, 1);
    }
    else {
      _transferFromSenderAndApproveTo(IERC20(sourceToken), sourceAmount, address(bancorNetwork));
      returnAmount = bancorNetwork.claimAndConvert(pathInERC20, sourceAmount, 1);
    }

    setTokenType(destinationToken, "BANCOR_ASSET");
 }


  /**
  * @dev Transfers tokens to this contract and approves them to another address
  *
  * @param _source          Token to transfer and approve
  * @param _sourceAmount    The amount to transfer and approve (in _source token)
  * @param _to              Address to approve to
  */
  function _transferFromSenderAndApproveTo(IERC20 _source, uint256 _sourceAmount, address _to) private {
    require(_source.transferFrom(msg.sender, address(this), _sourceAmount));
    // reset previos approve because some tokens require allowance 0
    _source.approve(_to, 0);
    // approve
    _source.approve(_to, _sourceAmount);
  }


  /**
  * @dev buy Compound cTokens
  *
  * @param _amount       amount of ERC20 or ETH
  * @param _cToken       cToken address
  */
  function compoundMint(uint256 _amount, address _cToken)
   external
   override
   payable
   returns(uint256)
  {
    uint256 receivedAmount = 0;
    if(_cToken == address(cEther)){
      // mint cETH
      cEther.mint.value(_amount)();
      // transfer received cETH back to fund
      receivedAmount = cEther.balanceOf(address(this));
      cEther.transfer(msg.sender, receivedAmount);
    }else{
      // mint cERC20
      CToken cToken = CToken(_cToken);
      address underlyingAddress = cToken.underlying();
      _transferFromSenderAndApproveTo(IERC20(underlyingAddress), _amount, address(_cToken));
      cToken.mint(_amount);
      // transfer received cERC back to fund
      receivedAmount = cToken.balanceOf(address(this));
      cToken.transfer(msg.sender, receivedAmount);
    }

    require(receivedAmount > 0, "received amount can not be zerro");

    setTokenType(_cToken, "COMPOUND");
    return receivedAmount;
  }

  /**
  * @dev sell certain percent of Ctokens to Compound
  *
  * @param _percent      percent from 1 to 100
  * @param _cToken       cToken address
  */
  function compoundRedeemByPercent(uint _percent, address _cToken)
   external
   override
   returns(uint256)
  {
    uint256 receivedAmount = 0;

    uint256 amount = getPercentFromCTokenBalance(_percent, _cToken, msg.sender);

    // transfer amount from sender
    IERC20(_cToken).transferFrom(msg.sender, address(this), amount);

    // reedem
    if(_cToken == address(cEther)){
      // redeem compound ETH
      cEther.redeem(amount);
      // transfer received ETH back to fund
      receivedAmount = address(this).balance;
      (msg.sender).transfer(receivedAmount);

    }else{
      // redeem ERC20
      CToken cToken = CToken(_cToken);
      cToken.redeem(amount);
      // transfer received ERC20 back to fund
      address underlyingAddress = cToken.underlying();
      IERC20 underlying = IERC20(underlyingAddress);
      receivedAmount = underlying.balanceOf(address(this));
      underlying.transfer(msg.sender, receivedAmount);
    }

    require(receivedAmount > 0, "received amount can not be zerro");

    return receivedAmount;
  }

  // VIEW Functions

  function tokenBalance(IERC20 _token) private view returns (uint256) {
    if (_token == ETH_TOKEN_ADDRESS)
      return address(this).balance;
    return _token.balanceOf(address(this));
  }

  /**
  * @dev Gets the ratio by amount of token _from in token _to by totekn type
  *
  * @param _from      Address of token we're converting from
  * @param _to        Address of token we're getting the value in
  * @param _amount    The amount of _from
  *
  * @return best price from 1inch for ERC20, or ratio for Uniswap and Bancor pools
  */
  function getValue(address _from, address _to, uint256 _amount)
    public
    override
    view
    returns (uint256)
  {
    if(_amount > 0){
      // get asset type
      bytes32 assetType = tokensTypes.getType(_from);

      // get value by asset type
      if(assetType == bytes32("CRYPTOCURRENCY")){
        return getValueViaDEXsAgregators(_from, _to, _amount);
      }
      else if (assetType == bytes32("BANCOR_ASSET")){
        return getValueViaBancor(_from, _to, _amount);
      }
      else if (assetType == bytes32("UNISWAP_POOL")){
        return getValueForUniswapPools(_from, _to, _amount);
      }
      else if (assetType == bytes32("UNISWAP_POOL_V2")){
        return getValueForUniswapV2Pools(_from, _to, _amount);
      }
      else if (assetType == bytes32("BALANCER_POOL")){
        return getValueForBalancerPool(_from, _to, _amount);
      }
      else if (assetType == bytes32("COMPOUND")){
        return getValueViaCompound(_from, _to, _amount);
      }
      else{
        // Unmarked type, try find value
        return findValue(_from, _to, _amount);
      }
    }
    else{
      return 0;
    }
  }

  /**
  * @dev find the ratio by amount of token _from in token _to trying all available methods
  *
  * @param _from      Address of token we're converting from
  * @param _to        Address of token we're getting the value in
  * @param _amount    The amount of _from
  *
  * @return best price from 1inch for ERC20, or ratio for Uniswap and Bancor pools
  */
  function findValue(address _from, address _to, uint256 _amount) private view returns (uint256) {
     if(_amount > 0){
       // If 1inch return 0, check from Bancor network for ensure this is not a Bancor pool
       uint256 oneInchResult = getValueViaDEXsAgregators(_from, _to, _amount);
       if(oneInchResult > 0)
         return oneInchResult;

       // If Bancor return 0, check from Compound network for ensure this is not Compound asset
       uint256 bancorResult = getValueViaBancor(_from, _to, _amount);
       if(bancorResult > 0)
          return bancorResult;

       // If Compound return 0, check from Balancer pools for ensure this is not Balancer  pool
       uint256 compoundResult = getValueViaCompound(_from, _to, _amount);
       if(compoundResult > 0)
          return compoundResult;

       // If Balancer return 0, check from Uniswap pools for ensure this is not Uniswap pool
       uint256 balancerResult = getValueForBalancerPool(_from, _to, _amount);
       if(balancerResult > 0)
          return balancerResult;

       // If Uniswap return 0, check from Uniswap version 2 pools for ensure this is not Uniswap V2 pool
       uint256 uniswapResult = getValueForUniswapPools(_from, _to, _amount);
       if(uniswapResult > 0)
          return uniswapResult;

       // Uniswap V2 pools return 0 if these is not a Uniswap V2 pool
       return getValueForUniswapV2Pools(_from, _to, _amount);
     }
     else{
       return 0;
     }
  }


  // helper for get value via 1inch
  // in this interface can be added more DEXs aggregators
  function getValueViaDEXsAgregators(
    address _from,
    address _to,
    uint256 _amount
  )
  public view returns (uint256){
    // if direction the same, just return amount
    if(_from == _to)
       return _amount;

    // try get value via 1inch
    if(_amount > 0){
      // try get value from 1inch aggregator
      return getValueViaOneInch(_from, _to, _amount);
    }
    else{
      return 0;
    }
  }


  // helper for get ratio between assets in 1inch aggregator
  function getValueViaOneInch(
    address _from,
    address _to,
    uint256 _amount
  )
    public
    view
    returns (uint256 value)
  {
    // if direction the same, just return amount
    if(_from == _to)
       return _amount;

    // try get rate
    try oneInch.getExpectedReturn(
       IERC20(_from),
       IERC20(_to),
       _amount,
       10,
       oneInchFlags)
      returns(uint256 returnAmount, uint256[] memory distribution)
     {
       value = returnAmount;
     }
     catch{
       value = 0;
     }
  }


  // helper for get ratio between assets in Bancor network
  function getValueViaBancor(
    address _from,
    address _to,
    uint256 _amount
  )
    public
    view
    returns (uint256 value)
  {
    // if direction the same, just return amount
    if(_from == _to)
       return _amount;

    // try get rate
    if(_amount > 0){
      try poolPortal.getBancorRatio(_from, _to, _amount) returns(uint256 result){
        value = result;
      }catch{
        value = 0;
      }
    }else{
      return 0;
    }
  }


  // helper for get value via Balancer
  function getValueForBalancerPool(
    address _from,
    address _to,
    uint256 _amount
  )
    public
    view
    returns (uint256 value)
  {
    // get value for each pool share
    try poolPortal.getBalancerConnectorsAmountByPoolAmount(_amount, _from)
    returns(
      address[] memory tokens,
      uint256[] memory tokensAmount
    )
    {
     // convert and sum value via DEX aggregator
     for(uint i = 0; i < tokens.length; i++){
       value += getValueViaDEXsAgregators(tokens[i], _to, tokensAmount[i]);
     }
    }
    catch{
      value = 0;
    }
  }


  // helper for get value between Compound assets and ETH/ERC20
  // NOTE: _from should be COMPOUND cTokens,
  // amount should be 1e8 because cTokens support 8 decimals
  function getValueViaCompound(
    address _from,
    address _to,
    uint256 _amount
  ) public view returns (uint256 value) {

    // get underlying amount by cToken amount
    uint256 underlyingAmount = getCompoundUnderlyingRatio(
      _from,
      _amount
    );
    // convert underlying in _to
    if(underlyingAmount > 0){
      // get underlying address
      address underlyingAddress = (_from == address(cEther))
      ? address(ETH_TOKEN_ADDRESS)
      : CToken(_from).underlying();

      // get rate for underlying address via DEX aggregators
      return getValueViaDEXsAgregators(underlyingAddress, _to, underlyingAmount);
    }
    else{
      return 0;
    }
  }


  // helper for get underlying amount by cToken amount
  // NOTE: _from should be Compound token, amount = input * 1e8 (not 1e18)
  function getCompoundUnderlyingRatio(
    address _from,
    uint256 _amount
  )
    public
    view
    returns (uint256)
  {
    // return 0 for attempt get underlying for ETH
    if(_from == address(ETH_TOKEN_ADDRESS))
       return 0;

    // try get underlying ratio
    try CToken(_from).exchangeRateStored() returns(uint256 rate)
    {
      uint256 underlyingAmount = _amount.mul(rate).div(1e18);
      return underlyingAmount;
    }
    catch{
      return 0;
    }
  }


  // helper for get ratio between pools in Uniswap network
  // _from - should be uniswap pool address
  function getValueForUniswapPools(
    address _from,
    address _to,
    uint256 _amount
  )
  public
  view
  returns (uint256)
  {
    // get connectors amount
    try poolPortal.getUniswapConnectorsAmountByPoolAmount(
      _amount,
      _from
    ) returns (uint256 ethAmount, uint256 ercAmount)
    {
      // get ERC amount in ETH
      address token = poolPortal.getTokenByUniswapExchange(_from);
      uint256 ercAmountInETH = getValueViaDEXsAgregators(token, address(ETH_TOKEN_ADDRESS), ercAmount);
      // sum ETH with ERC amount in ETH
      uint256 totalETH = ethAmount.add(ercAmountInETH);

      // if _to == ETH no need additional convert, just return ETH amount
      if(_to == address(ETH_TOKEN_ADDRESS)){
        return totalETH;
      }
      // convert ETH into _to asset via 1inch
      else{
        return getValueViaDEXsAgregators(address(ETH_TOKEN_ADDRESS), _to, totalETH);
      }
    }catch{
      return 0;
    }
  }


  // helper for get ratio between pools in Uniswap network version 2
  // _from - should be uniswap pool address
  function getValueForUniswapV2Pools(
    address _from,
    address _to,
    uint256 _amount
  )
  public
  view
  returns (uint256)
  {
    // get connectors amount by pool share
    try poolPortal.getUniswapV2ConnectorsAmountByPoolAmount(
      _amount,
      _from
    ) returns (
      uint256 tokenAmountOne,
      uint256 tokenAmountTwo,
      address tokenAddressOne,
      address tokenAddressTwo
      )
    {
      // convert connectors amount via DEX aggregator
      uint256 amountOne = getValueViaDEXsAgregators(tokenAddressOne, _to, tokenAmountOne);
      uint256 amountTwo = getValueViaDEXsAgregators(tokenAddressTwo, _to, tokenAmountTwo);
      // return value
      return amountOne + amountTwo;
    }catch{
      return 0;
    }
  }

  /**
  * @dev return percent of compound cToken balance
  *
  * @param _percent       amount of ERC20 or ETH
  * @param _cToken        cToken address
  * @param _holder        address of cToken holder
  */
  function getPercentFromCTokenBalance(uint _percent, address _cToken, address _holder)
   public
   override
   view
   returns(uint256)
  {
    if(_percent == 100){
      return IERC20(_cToken).balanceOf(_holder);
    }
    else if(_percent > 0 && _percent < 100){
      uint256 currectBalance = IERC20(_cToken).balanceOf(_holder);
      return currectBalance.div(100).mul(_percent);
    }
    else{
      // not correct percent
      return 0;
    }
  }

  // get underlying by cToken
  function getCTokenUnderlying(address _cToken)
    external
    override
    view returns(address)
  {
    return CToken(_cToken).underlying();
  }

  /**
  * @dev Gets the total value of array of tokens and amounts
  *
  * @param _fromAddresses    Addresses of all the tokens we're converting from
  * @param _amounts          The amounts of all the tokens
  * @param _to               The token who's value we're converting to
  *
  * @return The total value of _fromAddresses and _amounts in terms of _to
  */
  function getTotalValue(
    address[] calldata _fromAddresses,
    uint256[] calldata _amounts,
    address _to)
    external
    override
    view
    returns (uint256)
  {
    uint256 sum = 0;
    for (uint256 i = 0; i < _fromAddresses.length; i++) {
      sum = sum.add(getValue(_fromAddresses[i], _to, _amounts[i]));
    }
    return sum;
  }

  // SETTERS Functions

  /**
  * @dev Allows the owner to disable/enable the buying of a token
  *
  * @param _token      Token address whos trading permission is to be set
  * @param _enabled    New token permission
  */
  function setToken(address _token, bool _enabled) external onlyOwner {
    disabledTokens[_token] = _enabled;
  }

  // owner can change oneInch
  function setNewOneInch(address _oneInch) external onlyOwner {
    oneInch = IOneSplitAudit(_oneInch);
  }

  // owner can set new pool portal
  function setNewPoolPortal(address _poolPortal) external onlyOwner {
    poolPortal = PoolPortalInterface(_poolPortal);
  }

  // owner of portal can update 1 incg DEXs sources
  function setOneInchFlags(uint256 _oneInchFlags) external onlyOwner {
    oneInchFlags = _oneInchFlags;
  }

  // owner of portal can change getBancorData helper, for case if Bancor do some major updates
  function setNewGetBancorData(address _bancorData) external onlyOwner {
    bancorData = IGetBancorData(_bancorData);
  }


  // Exchange portal can mark each token
  function setTokenType(address _token, string memory _type) private {
    // no need add type, if token alredy registred
    if(tokensTypes.isRegistred(_token))
      return;

    tokensTypes.addNewTokenType(_token,  _type);
  }

  // fallback payable function to receive ether from other contract addresses
  fallback() external payable {}

}
