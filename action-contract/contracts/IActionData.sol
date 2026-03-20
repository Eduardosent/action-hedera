// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IActionData {
    struct UserAccount {
        address wallet;
        bool isBlacklisted;    // Regulatory compliance (AML/Sanctions/Fugitive)
        bool kycApproved;      // Verification status for RWA investment
    }

    enum ProjectStatus { 
        Presale,     // 0
        PublicSale,  // 1
        Development, // 2
        Profits,     // 3
        Cancelled    // 4
    }

    struct Project {
        address admin;                  // Project administrator
        address projectToken;           // RWA Token ID (project_mint)
        address fundingToken;           // Stablecoin accepted (the money coming in)
        // Financial Data (8 bytes - u64)
        uint64 totalProfitsDeposited;   
        uint64 balanceAtCancellation;   
        uint64 targetFunding;
        uint64 withdrawnFunding;              
        int64 cancellationTimestamp;          
        // Sales Data (4 bytes - u32)
        uint32 totalShares;             
        uint32 sharePrice;              // Price per token (2 decimals: 1050 = $10.50)
        uint32 tokensSold;                  
        // Configuration (Packed in a single 32-byte slot)
        uint16 commissionRate;          // 10000 = 100%
        uint8 purchaseLimit;            // 0 = No limit
        bool commissionPaid;            
        ProjectStatus status;           
    }

    struct Investor {
        uint32 balance;    // Total tokens under contract custody
        uint32 locked;     // Tokens currently listed for sale in the market
        uint64 lastClaim;  // Dividend checkpoint (inherited from seller)
        uint64 totalClaimed; // Historical sum of all claimed profits (with decimals)
    }
}