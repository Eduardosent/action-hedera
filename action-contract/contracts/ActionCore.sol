// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./HederaTokenService.sol";
import "./IHederaTokenService.sol";
import "./IActionData.sol";

contract ActionCore is HederaTokenService {
    address public authority;
    address public treasury;

    mapping(address => bool) public operators;
    mapping(address => bool) public approvedStablecoins;
    // Users
    mapping(address => IActionData.UserAccount) public userAccounts;
    // Projects
    mapping(address => IActionData.Project) public projects;
    // Investor = Equivalent to deriving: [project_address, user_wallet]
    mapping(address => mapping(address => IActionData.Investor)) public investors;

    //Events
    // Stablecoins
    event StablecoinAdded(address indexed token);
    // Operators
    event OperatorAdded(address indexed operator);
    // Users
    event UserRegistered(address indexed user);
    event UserApproved(address indexed user, address indexed approvedBy);
    // Creating Projects
    event ProjectCreated(
    address indexed projectToken,
    address indexed admin,
    address fundingToken,
    string name,
    string symbol,
    uint64 targetFunding,
    uint32 totalShares,
    uint32 sharePrice,
    uint16 commissionRate,
    uint8 purchaseLimit,
    string metadata
    );
    // Users investing on Projects
    event SharesPurchased(
    address indexed projectToken,
    address indexed buyer,
    uint32 amount,
    uint64 totalCost,
    uint32 sharePrice,
    uint8 decimals,
    IActionData.ProjectStatus newStatus
    );
    // Platform commission
    event ProjectFeeCollected(
        address indexed projectToken,
        uint64 amount
    );
    // Capital released to the admin
    event ProjectFundsReleased(
        address indexed projectToken,
        address indexed admin,
        uint64 amount
    );

    // --- Modifiers ---
    
    modifier onlyAuthority() {
        require(msg.sender == authority, "Not the authority");
        _;
    }

    modifier onlyOperator() {
        require(operators[msg.sender] || msg.sender == authority, "Not authorized");
        _;
    }

    modifier onlyVerified() {
        require(userAccounts[msg.sender].kycApproved, "KYC not approved");
        require(!userAccounts[msg.sender].isBlacklisted, "User is blacklisted");
        _;
    }

    // --- Constructor ---

    constructor(address _treasury) {
        authority = msg.sender;
        treasury = _treasury;
    }

    /**
     * @dev Internal function to handle token association safely.
     * Response codes: 22 = Success, 13 = Already Associated.
     */
    function _safeAssociate(address _account, address _token) internal {
        int response = HederaTokenService.associateToken(_account, _token);
        require(response == 22 || response == 13, "Action: Association failed");
    }

    /**
     * @dev Calculates commission rates based on funding targets.
     * Values in basis points: 500 = 5%, 50 = 0.5%.
     */
    function calculateCommissionRate(uint256 _target) internal pure returns (uint16) {
        if (_target <= 1000) return 500;         // 5.00%
        if (_target <= 10000) return 400;        // 4.00%
        if (_target <= 200000) return 300;       // 3.00%
        if (_target <= 1000000) return 200;      // 2.00%
        if (_target <= 10000000) return 100;     // 1.00%
        return 50;                               // 0.50%
    }

    /**
     * @dev Authorizes a stablecoin and associates it with the contract.
     * @param _token Address of the stablecoin (e.g., USDC, USDT).
     */
    function addStablecoin(address _token) external onlyAuthority {
        require(_token != address(0), "Action: Invalid address");
        require(!approvedStablecoins[_token], "Action: Already approved");

        // Contract must be associated with the token to receive/transfer it
        _safeAssociate(address(this), _token);
        
        approvedStablecoins[_token] = true;

        emit StablecoinAdded(_token);
    }

    /**
     * @dev Directly adds an operator. 
     * Logging the event is enough for administrative tracking.
     */
    function addOperator(address _operator) external onlyAuthority {
        require(!operators[_operator], "Action: Already an operator");        
        operators[_operator] = true;
        
        emit OperatorAdded(_operator);
    }

    /**
     * @dev User self-initialization. 
     * Uses the wallet field to verify if the account already exists.
     */
    function createUserAccount() external {
        IActionData.UserAccount storage account = userAccounts[msg.sender];
        
        // Proper existence check using the wallet address
        require(account.wallet == address(0), "Action: Account already exists");
        
        account.wallet = msg.sender;
        account.kycApproved = false;
        account.isBlacklisted = false;

        emit UserRegistered(msg.sender);
    }

    /**
     * @dev Operator approves a user's account status.
     */
    function approveUserAccount(address _user) external onlyOperator {
        require(!userAccounts[_user].kycApproved, "Action: Already approved");
        userAccounts[_user].kycApproved = true;

        emit UserApproved(_user, msg.sender);
    }

    /**
     * @dev Creates a new RWA token project on Hedera using HTS.
     * @param _name Token name.
     * @param _symbol Token symbol.
     * @param _metadata IPFS CID for HIP-412 compliance.
     * @param _fundingToken Address of the approved stablecoin.
     * @param _targetFunding Total funding goal in stablecoin (6 decimals).
     * @param _totalShares Total indivisible supply (shares).
     * @param _purchaseLimit Max percentage of shares per user (0 for no limit, max 100).
     */
    function createProject(
        string memory _name,
        string memory _symbol,
        string memory _metadata, 
        address _fundingToken,
        uint64 _targetFunding,   
        uint32 _totalShares,     
        uint8 _purchaseLimit
    ) external onlyOperator returns (address) {
        
        // 1. Parameter validation and price calculation
        require(approvedStablecoins[_fundingToken], "Stablecoin not approved");
        require(_targetFunding > 0 && _totalShares > 0 && _purchaseLimit <= 100, "Invalid parameters");
        // Multiplied by 100 to handle 2 decimal precision for sharePrice
        uint256 calculatedPrice = (uint256(_targetFunding) * 100) / uint256(_totalShares);
        require(calculatedPrice > 0, "Price too low");
        require(calculatedPrice <= type(uint32).max, "Price overflow");
        
        // 2. Key configuration (Admin and Wipe)
        IHederaTokenService.TokenKey[] memory keys = new IHederaTokenService.TokenKey[](4);
        IHederaTokenService.KeyValue memory contractKey = IHederaTokenService.KeyValue({
            inheritAccountKey: false,
            contractId: address(this),
            ed25519: new bytes(0),
            ECDSA_secp256k1: new bytes(0),
            delegatableContractId: address(0)
        });

        keys[0] = IHederaTokenService.TokenKey(0, contractKey); // Admin
        keys[1] = IHederaTokenService.TokenKey(3, contractKey); // Wipe
        keys[2] = IHederaTokenService.TokenKey(4, contractKey); // Supply
        keys[3] = IHederaTokenService.TokenKey(7, contractKey); // Metadata

        // 3. HederaToken configuration
        IHederaTokenService.HederaToken memory token;
        token.name = _name;
        token.symbol = _symbol;
        token.treasury = address(this);
        token.memo = _metadata; 
        token.metadata = bytes(_metadata); // HIP-412 Standard
        token.tokenSupplyType = false; // Infinite supply
        token.maxSupply = 0;
        token.freezeDefault = false;
        token.tokenKeys = keys;
        token.expiry = IHederaTokenService.Expiry({
            second: 0,
            autoRenewAccount: address(this),
            autoRenewPeriod: 63072000 // ~2 years
        });

        // 4. Creating token project
        (int res, address projectToken) = HederaTokenService.createFungibleToken(
            token, 
            int64(uint64(_totalShares)), // Initial supply
            int32(0)  // Decimals: 0 for indivisible shares
        );
        
        // 22 is the response code for SUCCESS in HTS
        require(res == 22, "RWA creation failed"); 

        // 5. Map project data in Action Protocol storage
        uint16 commission = calculateCommissionRate(_targetFunding);

        projects[projectToken] = IActionData.Project({
            admin: msg.sender,
            projectToken: projectToken,
            fundingToken: _fundingToken,
            totalProfitsDeposited: 0,
            balanceAtCancellation: 0,
            targetFunding: _targetFunding,
            withdrawnFunding: 0,
            cancellationTimestamp: 0,
            totalShares: _totalShares,
            sharePrice: uint32(calculatedPrice),
            tokensSold: 0,
            commissionRate: commission,
            purchaseLimit: _purchaseLimit,
            commissionPaid: false,
            status: IActionData.ProjectStatus.Presale
        });

        // 6. Emit event for backend indexing
        emit ProjectCreated(
            projectToken,
            msg.sender,
            _fundingToken,
            _name,
            _symbol,
            _targetFunding,
            _totalShares,
            uint32(calculatedPrice),
            commission,
            _purchaseLimit,
            _metadata
        );

        return projectToken;
    }
    
    /**
     * @dev Buy RWA shares using project's specific funding token.
     * @param _projectToken RWA token address (Project ID).
     * @param _amount Number of shares to purchase.
     */
    function buyShares(address _projectToken, uint32 _amount) 
        external 
        onlyVerified 
    {
        IActionData.Project storage project = projects[_projectToken];
        IActionData.Investor storage investor = investors[_projectToken][msg.sender];
        
        // 1. Basic checks & Dividend Protection
        require(project.projectToken != address(0), "Action: Project not found");
        require(_amount > 0, "Action: Invalid amount");
        
        // Check if existing investor has unclaimed profits to avoid overwriting the checkpoint
        if (investor.balance > 0) {
            require(investor.lastClaim == project.totalProfitsDeposited, "Action: Claim pending profits first");
        }
        
        // 2. Access control per phase
        if (project.status == IActionData.ProjectStatus.Presale) {
            require(msg.sender == project.admin, "Action: Admin only during Presale");
        } else {
            require(project.status == IActionData.ProjectStatus.PublicSale, "Action: Not in PublicSale");
        }

        // 3. Supply and limits (Admin is exempt)
        require(project.tokensSold + _amount <= project.totalShares, "Action: Cap reached");
        
        if (project.purchaseLimit > 0 && msg.sender != project.admin) {
            uint32 userTotal = investor.balance + _amount;
            uint32 maxAllowed = (project.totalShares * project.purchaseLimit) / 100;
            require(userTotal <= maxAllowed, "Action: Limit exceeded");
        }

        // 4. Dynamic decimal and price calculation
        (int res, IHederaTokenService.FungibleTokenInfo memory info) = 
            HederaTokenService.getFungibleTokenInfo(project.fundingToken);
        
        require(res == 22, "Action: HTS info failed");

        uint8 tokenDecimals = uint8(uint32(info.decimals));
        // formula: shares * price * 10^(decimals - 2)
        // price has 2 decimals, so we adjust by (decimals - 2) to get the correct HTS amount (example: price 1000 = $10.00)
        uint256 exp = uint256(tokenDecimals) - 2; 
        uint256 totalCost256 = uint256(_amount) * uint256(project.sharePrice) * (10**exp);
        
        // Safety check for uint64 conversion
        require(totalCost256 <= type(uint64).max, "Action: Total cost overflow");
        uint64 finalCost = uint64(totalCost256);

        // 5. Escrow transfer (User -> Contract)
        int64 htsAmount = int64(finalCost);
        int transferRes = HederaTokenService.transferToken(
            project.fundingToken, 
            msg.sender, 
            address(this), 
            htsAmount
        );
        require(transferRes == 22, "Action: Transfer failed");

        // 6. Record keeping
        investor.balance += _amount;
        investor.lastClaim = project.totalProfitsDeposited; 
        
        project.tokensSold += _amount;
        
        // Update Project status
        if (project.tokensSold == project.totalShares) {
            project.status = IActionData.ProjectStatus.Development;
        }

        // 7. Emit Event
        emit SharesPurchased(
            _projectToken,
            msg.sender,
            _amount,
            finalCost,
            project.sharePrice,
            tokenDecimals,
            project.status
        );
    }

    /**
     * @dev Releases funds to the project administrator.
     * The platform commission is only processed during the very first withdrawal.
     * @param _projectToken RWA token address.
     * @param _amount Amount to release in atomic units (including decimals).
     */
    function withdrawFunding(address _projectToken, uint64 _amount) 
        external 
        onlyOperator 
    {
        IActionData.Project storage project = projects[_projectToken];
        require(project.projectToken != address(0), "Action: Project not found");
        require(project.status == IActionData.ProjectStatus.Development, "Action: Not in Development");

        // 1. Get decimals for full precision scaling
        (int res, IHederaTokenService.FungibleTokenInfo memory info) = 
            HederaTokenService.getFungibleTokenInfo(project.fundingToken);
        require(res == 22, "Action: HTS info failed");
        
        uint256 decimalsMultiplier = 10**uint256(uint32(info.decimals));
        // Atomic target for all following calculations
        uint256 targetAtomics = uint256(project.targetFunding) * decimalsMultiplier;

        // 2. One-time commission processing
        if (!project.commissionPaid) {
            // Precision Fix: Calculate percentage AFTER scaling to atomics
            uint64 atomicFee = uint64((targetAtomics * uint256(project.commissionRate)) / 10000);
            project.commissionPaid = true;
            
            // Increment withdrawn tracker with the exact atomic fee
            project.withdrawnFunding += atomicFee;
            
            // Transfer exact atomic fee to Treasury via HTS
            require(HederaTokenService.transferToken(
                project.fundingToken, 
                address(this), 
                treasury, 
                int64(atomicFee)
            ) == 22, "Action: Treasury fee failed");

            emit ProjectFeeCollected(_projectToken, atomicFee);
        }

        // 3. Validation: Comparing ATOMIC units vs ATOMIC target
        // withdrawnFunding and _amount are already in atomic units
        require(uint256(project.withdrawnFunding) + _amount <= targetAtomics, "Action: Exceeds targetFunding");

        // 4. Update state and execute transfer to Project Admin
        project.withdrawnFunding += _amount;

        require(HederaTokenService.transferToken(
            project.fundingToken, 
            address(this), 
            project.admin, 
            int64(_amount)
        ) == 22, "Action: Admin transfer failed");

        emit ProjectFundsReleased(_projectToken, project.admin, _amount);

        // 5. Status Transition: Using atomic comparison
        // Threshold: If remaining funding is less than 1 whole unit (1 * 10^decimals)
        if ((targetAtomics - project.withdrawnFunding) < decimalsMultiplier) {
            project.status = IActionData.ProjectStatus.Profits;
        }
    }

}