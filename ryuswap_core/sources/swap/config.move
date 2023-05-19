/// The global config for ryufinance: fees and manager accounts (admins).
module ryufinance::config {

    use sui::tx_context;
    use sui::tx_context::TxContext;
    use sui::transfer;
    use sui::event;
    use sui::object::UID;
    use sui::object;
    friend ryufinance::swap;

    // Error codes.

    /// When config doesn't exists.
    const ERR_CONFIG_DOES_NOT_EXIST: u64 = 300;

    /// When user is not admin
    const ERR_NOT_ADMIN: u64 = 301;

    /// When invalid fee amount
    const ERR_INVALID_FEE: u64 = 302;

    /// Unreachable, is a bug if thrown
    const ERR_UNREACHABLE: u64 = 303;

    // Constants.

    /// Minimum value of fee, 0.01%
    const MIN_FEE: u64 = 1;

    /// Maximum value of fee, 1%
    const MAX_FEE: u64 = 100;

    /// Minimum value of dao fee, 0%
    const MIN_DAO_FEE: u64 = 0;

    /// Maximum value of dao fee, 100%
    const MAX_DAO_FEE: u64 = 100;

    /// The global configuration (fees and admin accounts).
    struct Config has key {
        id: UID,
        dao_admin_address: address,
        emergency_admin_address: address,
        fee_admin_address: address,
        default_swap_fee: u64,
        default_dao_fee: u64,
    }

    /// Event struct when fee updates.
    struct UpdateDefaultFeeEvent has drop, copy {
        fee: u64,
    }

    /// Initializes admin contracts when initializing the liquidity pool.
    public(friend) fun initialize(ctx: &mut TxContext) {
        assert!(tx_context::sender(ctx) == @dao_admin, ERR_UNREACHABLE);
        transfer::share_object(Config {
            id: object::new(ctx),
            dao_admin_address: @dao_admin,
            emergency_admin_address: @emergency_admin,
            fee_admin_address: @fee_admin,
            default_swap_fee: 30, // 0.3%
            default_dao_fee: 33, // 33%
        });
    }


    /// Get fee admin address.
    public fun get_fee_admin(config: &Config): address {
        config.fee_admin_address
    }

    /// Set fee admin account.
    public entry fun set_fee_admin(config: &mut Config, new_addr: address, ctx: &mut TxContext) {
        assert!(tx_context::sender(ctx) == @dao_admin, ERR_NOT_ADMIN);
        config.fee_admin_address = new_addr;
    }

    /// Get default fee for pool.
    /// IMPORTANT: use functions in Liquidity Pool module as pool fees could be different from default ones.
    public fun get_default_fee(config: &Config): u64 {
        config.default_swap_fee
    }

    /// Set new default fee.
    public entry fun set_default_fee(config: &mut Config, default_fee: u64, ctx: &mut TxContext) {
        assert!(config.fee_admin_address == tx_context::sender(ctx), ERR_NOT_ADMIN);

        assert_valid_fee(default_fee);
        config.default_swap_fee = default_fee;
        event::emit(UpdateDefaultFeeEvent { fee: default_fee });
    }

    /// Get default DAO fee.
    public fun get_default_dao_fee(config: &Config): u64 {
        config.default_dao_fee
    }

    /// Set default DAO fee.
    public entry fun set_default_dao_fee(config: &mut Config, default_fee: u64, ctx: &mut TxContext) {
        assert!(config.fee_admin_address == tx_context::sender(ctx), ERR_NOT_ADMIN);

        assert_valid_dao_fee(default_fee);

        config.default_dao_fee = default_fee;

        event::emit(UpdateDefaultFeeEvent { fee: default_fee });
    }

    /// Aborts if fee is valid.
    public fun assert_valid_fee(fee: u64) {
        assert!(MIN_FEE <= fee && fee <= MAX_FEE, ERR_INVALID_FEE);
    }

    /// Aborts if dao fee is valid.
    public fun assert_valid_dao_fee(dao_fee: u64) {
        assert!(MIN_DAO_FEE <= dao_fee && dao_fee <= MAX_DAO_FEE, ERR_INVALID_FEE);
    }


    /// Get DAO admin address.
    public fun get_dao_admin(config: &Config): address {
        config.dao_admin_address
    }

    /// Set DAO admin account.
    public entry fun set_dao_admin(config: &mut Config, new_addr: address, ctx: &mut TxContext) {
        assert!(tx_context::sender(ctx) == @dao_admin, ERR_NOT_ADMIN);
        config.dao_admin_address = new_addr;
    }


    /// Get emergency admin address.
    public fun get_emergency_admin(config: &Config): address {
        config.emergency_admin_address
    }

    /// Set emergency admin account.
    public entry fun set_emergency_admin(config: &mut Config, new_addr: address, ctx: &mut TxContext) {
        assert!(tx_context::sender(ctx) == @dao_admin, ERR_NOT_ADMIN);
        config.emergency_admin_address = new_addr;
    }
}
