//SPDX-License-Identifier: Apache-2.0	
pragma solidity ^0.7.1;
pragma experimental ABIEncoderV2;

import '@nomiclabs/buidler/console.sol';
import "./ERC1155.sol";
import "./IERC1155Views.sol";

contract TokensFlow is ERC1155, IERC1155Views {
    using SafeMath for uint256;
    using Address for address;

    struct TokenFlow {
        uint256 parentToken;
        int256 maxSwapCredit;
        int swapCreditPeriod;
        int timeEnteredSwapCredit; // zero means not in a swap credit
        int lastSwapTime; // ignored when not in a swap credit
        int256 remainingSwapCredit;
        bool enabled;
        bool recurring;
    }

    uint256 public maxTokenId;

    mapping (uint256 => address) public tokenOwners;

    mapping (uint256 => TokenFlow) public tokenFlow;

// IERC1155Views

    mapping (uint256 => uint256) private totalSupplyImpl;
    mapping (uint256 => string) private nameImpl;
    mapping (uint256 => string) private symbolImpl;
    mapping (uint256 => string) private uriImpl;

    function totalSupply(uint256 _id) external override view returns (uint256) {
        return totalSupplyImpl[_id];
    }

    function name(uint256 _id) external override view returns (string memory) {
        return nameImpl[_id];
    }

    function symbol(uint256 _id) external override view returns (string memory) {
        return symbolImpl[_id];
    }

    function decimals(uint256) external override pure returns (uint8) {
        return 18;
    }

    function uri(uint256 _id) external override view returns (string memory) {
        return uriImpl[_id];
    }

// Administrativia

    function newToken(uint256 _parent, string calldata _name, string calldata _symbol, string calldata _uri)
        external returns (uint256)
    {
        return _newToken(_parent, _name, _symbol, _uri, msg.sender);
    }

    function setTokenOwner(uint256 _id, address _newOwner) external {
        require(msg.sender == tokenOwners[_id]);
        require(_id != 0);

        tokenOwners[_id] = _newOwner;
    }

    function removeTokenOwner(uint256 _id) external {
        require(msg.sender == tokenOwners[_id]);

        tokenOwners[_id] = address(0);
    }

    // Intentially no setTokenName() and setTokenSymbol()
    function setTokenUri(uint256 _id, string calldata _uri) external {
        require(msg.sender == tokenOwners[_id]);

        uriImpl[_id] = _uri;
    }

    // We don't check for circularities.
    function setTokenParent(uint256 _child, uint256 _parent) external {
        // require(_child != 0 && _child <= maxTokenId); // not needed
        require(msg.sender == tokenOwners[_child]);

        _setTokenParentNoCheck(_child, _parent);
    }

    // Each element of `_childs` list must be a child of the next one.
    // TODO: Test. Especially test the case if the last child has no parent. Also test if a child is zero.
    function setEnabled(uint256[] calldata _childs, bool _enabled) external {
        uint256 _firstChild = _childs[0]; // asserts on `_childs.length == 0`.
        bool _hasRight = false; // if msg.sender is an ancestor

        // Note that if in the below loops we disable ourselves, then it will be detected by a require

        uint i = 0;
        uint256 _parent;
        for (uint256 _id = _firstChild; _id != 0; _id = _parent) {
            _parent = tokenFlow[_id].parentToken;
            if (i < _childs.length - 1) {
                require(_parent == _childs[i + 1]);
            }
            if (msg.sender == tokenOwners[_id]) {
                require(tokenFlow[_id].enabled);
                _hasRight = true;
                break;
            }
            // We are not msg.sender
            tokenFlow[_id].enabled = _enabled; // cannot enable for msg.sender
            ++i;
        }

        require(_hasRight);
    }

    // User can set negative values. It is a nonsense but does not harm.
    function setRecurringFlow(
        uint256 _child,
        int256 _maxSwapCredit,
        int256 _remainingSwapCredit,
        int _swapCreditPeriod, int _timeEnteredSwapCredit) external
    {
        TokenFlow storage _flow = tokenFlow[_child];

        require(msg.sender == tokenOwners[_flow.parentToken]);
        // require(_remainingSwapCredit <= _maxSwapCredit); // It is caller's responsibility.

        _flow.maxSwapCredit = _maxSwapCredit;
        _flow.swapCreditPeriod = _swapCreditPeriod;
        _flow.timeEnteredSwapCredit = _timeEnteredSwapCredit;
        _flow.remainingSwapCredit = _remainingSwapCredit;
        _flow.recurring = true;
    }

    // User can set negative values. It is a nonsense but does not harm.
    function setNonRecurringFlow(uint256 _child, int256 _remainingSwapCredit) external {
        TokenFlow storage _flow = tokenFlow[_child];

        require(msg.sender == tokenOwners[_flow.parentToken]);
        // require(_remainingSwapCredit <= _maxSwapCredit); // It is caller's responsibility.

        _flow.remainingSwapCredit = _remainingSwapCredit;
        _flow.recurring = false;
    }

// ERC-1155

    function safeTransferFrom(
        address _from,
        address _to,
        uint256 _id,
        uint256 _value,
        bytes calldata _data) external virtual override
    {
        require(tokenFlow[_id].enabled);
        super._safeTransferFrom(_from, _to, _id, _value, _data);
    }

    function safeBatchTransferFrom(
        address _from,
        address _to,
        uint256[] calldata _ids,
        uint256[] calldata _values,
        bytes calldata _data) external virtual override
    {
        for (uint i = 0; i < _ids.length; ++i) {
            require(tokenFlow[_ids[i]].enabled);
        }
        super._safeBatchTransferFrom(_from, _to, _ids, _values, _data);
    }

// Misc

    function burn(address _from, uint256 _id, uint256 _value) external {
        if(_from != msg.sender) {
            allowanceImpl[_id][_from][msg.sender] = allowanceImpl[_id][_from][msg.sender].sub(_value);
        }

        // SafeMath will throw with insuficient funds _from
        // or if _id is not valid (balance will be 0)
        balances[_id][_from] = balances[_id][_from].sub(_value);
        totalSupplyImpl[_id] -= _value; // no need to check overflow due to previous line

        emit TransferSingle(msg.sender, _from, address(0), _id, _value);
    }

// Flow

    // TODO: Test for `_ids.length != 1`.
    function exchangeToAncestor(uint256[] calldata _ids, uint256 _amount, bytes calldata _data) external {
        // Intentionally no check for `msg.sender`.
        require(_ids[_ids.length - 1] != 0); // The rest elements are checked below.
        for(uint i = 0; i != _ids.length - 1; ++i) {
            uint256 _id = _ids[i];
            require(_id != 0);
            uint256 _parent = tokenFlow[_id].parentToken;
            require(_parent == _ids[i + 1]); // i ranges 0 .. _ids.length - 2
            TokenFlow storage _flow = tokenFlow[_id];
            int _currentTimeResult = _currentTime();
            uint256 _maxAllowedFlow;
            bool _inSwapCreditResult;
            if (_flow.recurring) {
                _inSwapCreditResult = _inSwapCredit(_flow, _currentTimeResult);
                _maxAllowedFlow = _maxRecurringSwapAmount(_flow, _currentTimeResult, _inSwapCreditResult);
            } else {
                _maxAllowedFlow = _flow.remainingSwapCredit < 0 ? 0 : uint256(_flow.remainingSwapCredit);
            }
            require(_amount <= _maxAllowedFlow);
            require(_amount < 1<<128);
            uint256 _balance = balances[_id][msg.sender];
            require(_amount <= _balance);
            if (_flow.recurring && !_inSwapCreditResult) {
                _flow.timeEnteredSwapCredit = _currentTimeResult;
                _flow.remainingSwapCredit = _flow.maxSwapCredit;
            }
            _flow.lastSwapTime = _currentTimeResult; // TODO: no strictly necessary if !_flow.recurring
            // require(_amount < 1<<128); // done above
            _flow.remainingSwapCredit -= int256(_amount);
        }

        // if (_id == _flow.parentToken) return; // not necessary
        _doBurn(msg.sender, _ids[0], _amount);
        _doMint(msg.sender, _ids[_ids.length - 1], _amount, _data);
    }

// Internal

    function _newToken(uint256 _parent,
                        string memory _name, string memory _symbol, string memory _uri,
                        address _owner)
        internal returns (uint256)
    {
        tokenOwners[++maxTokenId] = _owner;

        nameImpl[maxTokenId] = _name;
        symbolImpl[maxTokenId] = _symbol;
        uriImpl[maxTokenId] = _uri;

        _setTokenParentNoCheck(maxTokenId, _parent);

        emit NewToken(maxTokenId, _owner, _name, _symbol, _uri);

        return maxTokenId;
    }

    function _doMint(address _to, uint256 _id, uint256 _value, bytes memory _data) public {
        require(_to != address(0), "_to must be non-zero.");

        if (_value != 0) {
            totalSupplyImpl[_id] = _value.add(totalSupplyImpl[_id]);
            balances[_id][_to] += _value; // no need to check for overflow due to the previous line
        }

        // MUST emit event
        emit TransferSingle(msg.sender, address(0), _to, _id, _value);

        // Now that the balance is updated and the event was emitted,
        // call onERC1155Received if the destination is a contract.
        if (_to.isContract()) {
            _doSafeTransferAcceptanceCheck(msg.sender, address(0), _to, _id, _value, _data);
        }
    }

    function _doBurn(address _from, uint256 _id, uint256 _value) public {
        // require(_from != address(0), "_from must be non-zero.");

        balances[_id][_from] = balances[_id][_from].sub(_value);
        totalSupplyImpl[_id] -= _value; // no need to check for overflow due to the previous line

        // MUST emit event
        emit TransferSingle(msg.sender, _from, address(0), _id, _value);
    }

    // Also resets swap credits and `enabled`, so use with caution.
    // Allow this even if `!enabled` and set `enabled` to `true` if no parent,
    // as otherwise impossible to enable it again.
    function _setTokenParentNoCheck(uint256 _child, uint256 _parent) internal virtual {
        require(_parent <= maxTokenId);

        tokenFlow[_child] = TokenFlow({
            parentToken: _parent,
            maxSwapCredit: 0,
            swapCreditPeriod: 0,
            timeEnteredSwapCredit: 0, // zero means not in a swap credit
            lastSwapTime: 0,
            remainingSwapCredit: 0,
            enabled: _parent == 0,
            recurring: false
        });
    }

    function _currentTime() internal virtual view returns(int) {
        return int(block.timestamp);
    }

    function _inSwapCredit(TokenFlow memory _flow, int _currentTimeResult) public pure returns(bool) {
        // solhint-disable indent
        return _flow.timeEnteredSwapCredit != 0 &&
            _currentTimeResult - _flow.timeEnteredSwapCredit < _flow.swapCreditPeriod;
    }

    function _maxRecurringSwapAmount(TokenFlow memory _flow, int _currentTimeResult, bool _inSwapCreditResult)
        public pure returns(uint256)
    {
        int256 result;
        if (_inSwapCreditResult) {
            int256 passedTime = _currentTimeResult - _flow.lastSwapTime;
            int256 delta = _flow.maxSwapCredit * passedTime / _flow.swapCreditPeriod;
            result = _flow.remainingSwapCredit - delta;
        } else {
            result = _flow.maxSwapCredit;
        }
        return result < 0 ? 0 : uint256(result);
    }

// Events

    event NewToken(uint256 indexed id, address indexed owner, string name, string symbol, string uri);
}
