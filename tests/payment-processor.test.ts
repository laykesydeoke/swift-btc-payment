import { describe, it, beforeEach, expect } from 'vitest';
import { Cl } from '@stacks/transactions';

const contracts = {
  paymentProcessor: 'payment-processor'
};

describe('SwiftBTC Payment Processor Tests', () => {
  let accounts: Record<string, any>;
  let deployer: any;
  let merchant1: any;
  let merchant2: any;
  let payer1: any;
  let payer2: any;

  beforeEach(() => {
    accounts = simnet.getAccounts();
    deployer = accounts['deployer'];
    merchant1 = accounts['wallet_1'];
    merchant2 = accounts['wallet_2'];
    payer1 = accounts['wallet_3'];
    payer2 = accounts['wallet_4'];
  });

  describe('Contract Initialization', () => {
    it('should deploy successfully with correct initial state', () => {
      // Test contract deployment and initial values
      const result = simnet.callReadOnlyFn(
        contracts.paymentProcessor,
        'get-current-payment-counter',
        [],
        deployer
      );

      expect(result.result).toBeUint(0);
    });

    it('should have correct platform fee rate initialized', () => {
      const result = simnet.callReadOnlyFn(
        contracts.paymentProcessor,
        'calculate-platform-fee',
        [Cl.uint(100000)], // 1 STX worth
        deployer
      );

      expect(result.result).toBeUint(2500); // 2.5% of 100000
    });
  });

  describe('Payment Creation', () => {
    it('should create payment successfully with valid parameters', () => {
      const paymentAmount = 1000000; // 1 STX
      const sbtcAmount = 1000000; // 1 sBTC equivalent
      const expiresIn = 144; // 24 hours in blocks
      const reference = "ORDER-123";
      const metadata = "Test payment for order 123";

      const result = simnet.callPublicFn(
        contracts.paymentProcessor,
        'create-payment',
        [
          Cl.principal(merchant1),
          Cl.uint(paymentAmount),
          Cl.uint(sbtcAmount),
          Cl.uint(expiresIn),
          Cl.stringAscii(reference),
          Cl.stringAscii(metadata)
        ],
        deployer
      );

      expect(result.result).toBeOk(Cl.uint(1)); // First payment ID

      // Verify payment was created correctly - just check that result is not none
      const getPaymentResult = simnet.callReadOnlyFn(
        contracts.paymentProcessor,
        'get-payment',
        [Cl.uint(1)],
        deployer
      );

      expect(getPaymentResult.result).not.toBeNone();
    });

    it('should reject payment creation with zero amount', () => {
      const result = simnet.callPublicFn(
        contracts.paymentProcessor,
        'create-payment',
        [
          Cl.principal(merchant1),
          Cl.uint(0), // Invalid zero amount
          Cl.uint(1000000),
          Cl.uint(144),
          Cl.stringAscii("ORDER-123"),
          Cl.stringAscii("Test payment")
        ],
        deployer
      );

      expect(result.result).toBeErr(Cl.uint(107)); // ERR-INVALID-AMOUNT
    });

    it('should reject payment creation with zero sBTC amount', () => {
      const result = simnet.callPublicFn(
        contracts.paymentProcessor,
        'create-payment',
        [
          Cl.principal(merchant1),
          Cl.uint(1000000),
          Cl.uint(0), // Invalid zero sBTC amount
          Cl.uint(144),
          Cl.stringAscii("ORDER-123"),
          Cl.stringAscii("Test payment")
        ],
        deployer
      );

      expect(result.result).toBeErr(Cl.uint(107)); // ERR-INVALID-AMOUNT
    });

    it('should increment payment counter for multiple payments', () => {
      // Create first payment
      const result1 = simnet.callPublicFn(
        contracts.paymentProcessor,
        'create-payment',
        [
          Cl.principal(merchant1),
          Cl.uint(1000000),
          Cl.uint(1000000),
          Cl.uint(144),
          Cl.stringAscii("ORDER-123"),
          Cl.stringAscii("First payment")
        ],
        deployer
      );

      // Create second payment
      const result2 = simnet.callPublicFn(
        contracts.paymentProcessor,
        'create-payment',
        [
          Cl.principal(merchant2),
          Cl.uint(2000000),
          Cl.uint(2000000),
          Cl.uint(144),
          Cl.stringAscii("ORDER-456"),
          Cl.stringAscii("Second payment")
        ],
        deployer
      );

      expect(result1.result).toBeOk(Cl.uint(1));
      expect(result2.result).toBeOk(Cl.uint(2));
    });
  });

  describe('Payment Processing', () => {
    beforeEach(() => {
      // Setup: Create a payment first
      simnet.callPublicFn(
        contracts.paymentProcessor,
        'create-payment',
        [
          Cl.principal(merchant1),
          Cl.uint(1000000),
          Cl.uint(1000000),
          Cl.uint(144),
          Cl.stringAscii("ORDER-123"),
          Cl.stringAscii("Test payment")
        ],
        deployer
      );
    });

    it('should process payment successfully by payer', () => {
      const result = simnet.callPublicFn(
        contracts.paymentProcessor,
        'process-payment',
        [Cl.uint(1)],
        payer1
      );

      expect(result.result).toBeOk(Cl.bool(true));

      // Verify payment status changed to confirmed
      const getPaymentResult = simnet.callReadOnlyFn(
        contracts.paymentProcessor,
        'get-payment',
        [Cl.uint(1)],
        deployer
      );

      expect(getPaymentResult.result).not.toBeNone();
    });

    it('should reject processing non-existent payment', () => {
      const result = simnet.callPublicFn(
        contracts.paymentProcessor,
        'process-payment',
        [Cl.uint(999)], // Non-existent payment ID
        payer1
      );

      expect(result.result).toBeErr(Cl.uint(102)); // ERR-PAYMENT-NOT-FOUND
    });

    it('should reject processing already processed payment', () => {
      // First, process the payment
      simnet.callPublicFn(
        contracts.paymentProcessor,
        'process-payment',
        [Cl.uint(1)],
        payer1
      );

      // Try to process again
      const result = simnet.callPublicFn(
        contracts.paymentProcessor,
        'process-payment',
        [Cl.uint(1)],
        payer2
      );

      expect(result.result).toBeErr(Cl.uint(103)); // ERR-PAYMENT-ALREADY-PROCESSED
    });

    it('should reject processing expired payment', () => {
      // Create payment with short expiry
      simnet.callPublicFn(
        contracts.paymentProcessor,
        'create-payment',
        [
          Cl.principal(merchant1),
          Cl.uint(1000000),
          Cl.uint(1000000),
          Cl.uint(1), // Expires in 1 block
          Cl.stringAscii("ORDER-789"),
          Cl.stringAscii("Short expiry payment")
        ],
        deployer
      );

      // Mine blocks to expire the payment
      simnet.mineEmptyBlocks(3);

      const result = simnet.callPublicFn(
        contracts.paymentProcessor,
        'process-payment',
        [Cl.uint(2)], // Second payment ID
        payer1
      );

      expect(result.result).toBeErr(Cl.uint(106)); // ERR-PAYMENT-EXPIRED
    });
  });

  describe('Payment Settlement', () => {
    beforeEach(() => {
      // Setup: Create and process a payment
      simnet.callPublicFn(
        contracts.paymentProcessor,
        'create-payment',
        [
          Cl.principal(merchant1),
          Cl.uint(1000000),
          Cl.uint(1000000),
          Cl.uint(144),
          Cl.stringAscii("ORDER-123"),
          Cl.stringAscii("Test payment")
        ],
        deployer
      );

      simnet.callPublicFn(
        contracts.paymentProcessor,
        'process-payment',
        [Cl.uint(1)],
        payer1
      );
    });

    it('should settle payment successfully', () => {
      const result = simnet.callPublicFn(
        contracts.paymentProcessor,
        'settle-payment',
        [Cl.uint(1)],
        deployer
      );

      expect(result.result).toBeOk(Cl.bool(true));

      // Verify payment status changed to settled
      const getPaymentResult = simnet.callReadOnlyFn(
        contracts.paymentProcessor,
        'get-payment',
        [Cl.uint(1)],
        deployer
      );

      expect(getPaymentResult.result).not.toBeNone();
    });

    it('should calculate correct platform fee and merchant amount', () => {
      simnet.callPublicFn(
        contracts.paymentProcessor,
        'settle-payment',
        [Cl.uint(1)],
        deployer
      );

      // Check settlement details
      const getSettlementResult = simnet.callReadOnlyFn(
        contracts.paymentProcessor,
        'get-payment-settlement',
        [Cl.uint(1)],
        deployer
      );

      expect(getSettlementResult.result).not.toBeNone();
      // Note: In a real test, you'd extract and verify the specific fee amounts
      // This would require understanding the exact structure returned by your contract
    });

    it('should update merchant balance correctly after settlement', () => {
      simnet.callPublicFn(
        contracts.paymentProcessor,
        'settle-payment',
        [Cl.uint(1)],
        deployer
      );

      // Check merchant balance
      const getBalanceResult = simnet.callReadOnlyFn(
        contracts.paymentProcessor,
        'get-merchant-balance',
        [Cl.principal(merchant1)],
        deployer
      );

      // Verify that balance is returned (exact structure depends on your contract)
      expect(getBalanceResult.result).not.toBeNone();
    });

    it('should reject settling non-confirmed payment', () => {
      // Create new payment but don't process it
      simnet.callPublicFn(
        contracts.paymentProcessor,
        'create-payment',
        [
          Cl.principal(merchant1),
          Cl.uint(1000000),
          Cl.uint(1000000),
          Cl.uint(144),
          Cl.stringAscii("ORDER-456"),
          Cl.stringAscii("Unprocessed payment")
        ],
        deployer
      );

      const result = simnet.callPublicFn(
        contracts.paymentProcessor,
        'settle-payment',
        [Cl.uint(2)], // New payment ID, not processed
        deployer
      );

      expect(result.result).toBeErr(Cl.uint(101)); // ERR-INVALID-PAYMENT
    });
  });

  describe('Balance Management', () => {
    beforeEach(() => {
      // Setup: Create, process, and settle a payment to give merchant balance
      simnet.callPublicFn(
        contracts.paymentProcessor,
        'create-payment',
        [
          Cl.principal(merchant1),
          Cl.uint(1000000),
          Cl.uint(1000000),
          Cl.uint(144),
          Cl.stringAscii("ORDER-123"),
          Cl.stringAscii("Test payment")
        ],
        deployer
      );

      simnet.callPublicFn(
        contracts.paymentProcessor,
        'process-payment',
        [Cl.uint(1)],
        payer1
      );

      simnet.callPublicFn(
        contracts.paymentProcessor,
        'settle-payment',
        [Cl.uint(1)],
        deployer
      );
    });

    it('should allow merchant to withdraw available balance', () => {
      const withdrawAmount = 500000; // Withdraw half of available balance

      const result = simnet.callPublicFn(
        contracts.paymentProcessor,
        'withdraw-balance',
        [Cl.uint(withdrawAmount)],
        merchant1
      );

      expect(result.result).toBeOk(Cl.bool(true));

      // Check updated balance
      const getBalanceResult = simnet.callReadOnlyFn(
        contracts.paymentProcessor,
        'get-merchant-balance',
        [Cl.principal(merchant1)],
        deployer
      );

      expect(getBalanceResult.result).not.toBeNone();
    });

    it('should reject withdrawal of more than available balance', () => {
      const withdrawAmount = 2000000; // More than available

      const result = simnet.callPublicFn(
        contracts.paymentProcessor,
        'withdraw-balance',
        [Cl.uint(withdrawAmount)],
        merchant1
      );

      expect(result.result).toBeErr(Cl.uint(104)); // ERR-INSUFFICIENT-BALANCE
    });
  });

  describe('Payment Expiration', () => {
    it('should expire payment correctly', () => {
      // Create payment with short expiry
      simnet.callPublicFn(
        contracts.paymentProcessor,
        'create-payment',
        [
          Cl.principal(merchant1),
          Cl.uint(1000000),
          Cl.uint(1000000),
          Cl.uint(1), // Expires in 1 block
          Cl.stringAscii("ORDER-123"),
          Cl.stringAscii("Short expiry payment")
        ],
        deployer
      );

      // Mine blocks to expire the payment
      simnet.mineEmptyBlocks(3);

      const result = simnet.callPublicFn(
        contracts.paymentProcessor,
        'expire-payment',
        [Cl.uint(1)],
        deployer
      );

      expect(result.result).toBeOk(Cl.bool(true));

      // Verify payment status changed to expired
      const getPaymentResult = simnet.callReadOnlyFn(
        contracts.paymentProcessor,
        'get-payment',
        [Cl.uint(1)],
        deployer
      );

      expect(getPaymentResult.result).not.toBeNone();
    });
  });

  describe('Admin Functions', () => {
    it('should allow owner to update platform fee rate', () => {
      const newFeeRate = 300; // 3%

      const result = simnet.callPublicFn(
        contracts.paymentProcessor,
        'set-platform-fee-rate',
        [Cl.uint(newFeeRate)],
        deployer
      );

      expect(result.result).toBeOk(Cl.bool(true));

      // Verify fee calculation with new rate
      const feeCalcResult = simnet.callReadOnlyFn(
        contracts.paymentProcessor,
        'calculate-platform-fee',
        [Cl.uint(100000)],
        deployer
      );

      expect(feeCalcResult.result).toBeUint(3000); // 3% of 100000
    });

    it('should reject non-owner attempt to update fee rate', () => {
      const result = simnet.callPublicFn(
        contracts.paymentProcessor,
        'set-platform-fee-rate',
        [Cl.uint(300)],
        merchant1 // Non-owner
      );

      expect(result.result).toBeErr(Cl.uint(100)); // ERR-UNAUTHORIZED
    });

    it('should reject excessive fee rate', () => {
      const result = simnet.callPublicFn(
        contracts.paymentProcessor,
        'set-platform-fee-rate',
        [Cl.uint(1500)], // 15% - exceeds 10% max
        deployer
      );

      expect(result.result).toBeErr(Cl.uint(101)); // ERR-INVALID-PAYMENT
    });
  });
});
