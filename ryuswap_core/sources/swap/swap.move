/// Implements mint/burn liquidity, swap of coins.
module ryufinance::swap {
    use std::ascii::String;
    use sui::coin::{Coin};
    use sui::coin;
    use sui::balance::{Balance, Supply};
    use sui::tx_context::TxContext;
    use ryulib::coin_helper;
    use sui::balance;
    use ryulib::math;
    use sui::transfer;
    use sui::tx_context;
    use std::type_name;
    use sui::object::UID;
    use sui::object;
    use sui::dynamic_field;
    use sui::event;
    use ryulib::uq64x64;
    use ryulib::u256;
    use ryufinance::dao_fee;
    use ryufinance::dao_fee::DaoFeeInfo;
    use ryufinance::config;
    use ryufinance::config::Config;
    use sui::dynamic_object_field;
    use sui::clock::Clock;
    use sui::clock;
    // Error codes.

    /// When coins used to create pair have wrong ordering.
    const ERR_WRONG_PAIR_ORDERING: u64 = 1000;

    /// When pair already exists on account.
    const ERR_POOL_EXISTS_FOR_PAIR: u64 = 1001;

    /// When not enough liquidity minted.
    const ERR_NOT_ENOUGH_INITIAL_LIQUIDITY: u64 = 1002;

    /// When not enough liquidity minted.
    const ERR_NOT_ENOUGH_LIQUIDITY: u64 = 1003;

    /// When both X and Y provided for swap are equal zero.
    const ERR_EMPTY_COIN_IN: u64 = 1004;

    /// When incorrect INs/OUTs arguments passed during swap and math doesn't work.
    const ERR_INCORRECT_SWAP: u64 = 1005;

    /// Incorrect lp coin burn values
    const ERR_INCORRECT_BURN_VALUES: u64 = 1006;

    /// When pool doesn't exists for pair.
    const ERR_POOL_DOES_NOT_EXIST: u64 = 1007;

    /// Should never occur.
    const ERR_UNREACHABLE: u64 = 1008;

    /// When `initialize()` transaction is signed with any account other than @ryufinance.
    const ERR_NOT_ENOUGH_PERMISSIONS_TO_INITIALIZE: u64 = 1009;


    /// When pool is locked.
    const ERR_POOL_IS_LOCKED: u64 = 1011;

    /// When user is not admin
    const ERR_NOT_ADMIN: u64 = 1012;

    // Constants.

    /// Minimal liquidity.
    const MINIMAL_LIQUIDITY: u64 = 1000;

    /// Denominator to handle decimal points for fees.
    const FEE_SCALE: u64 = 10000;

    /// Denominator to handle decimal points for dao fee.
    const DAO_FEE_SCALE: u64 = 100;

    // Public functions.

    /// pair list
    struct RyuSwap has key {
        id: UID,
    }



    /// Liquidity pool with reserves.
    struct LiquidityPool<phantom X, phantom Y> has key, store {
        id: UID,
        coin_x_reserve: Balance<X>,
        coin_y_reserve: Balance<Y>,
        lsp_supply: Supply<LPCoin<X, Y>>,
        last_block_timestamp: u64,
        last_price_x_cumulative: u128,
        last_price_y_cumulative: u128,
        locked: bool,
        fee: u64,
        // 1 - 100 (0.01% - 1%)
        dao_fee: u64,
        // 0 - 100 (0% - 100%)
    }

    /// Liquidity pool with reserves.
    struct LPCoin<phantom X, phantom Y> has drop {}


    /// Initializes  contracts.
    public entry fun initialize(ctx: &mut TxContext) {
        assert!(tx_context::sender(ctx) == @dao_admin, ERR_NOT_ENOUGH_PERMISSIONS_TO_INITIALIZE);

        transfer::share_object(RyuSwap {
            id: object::new(ctx),
        });

        dao_fee::initialize(ctx);
        config::initialize(ctx);
    }

    /// For when supplied Coin is zero.
    const EZeroAmount: u64 = 0;

    /// For when pool fee is set incorrectly.
    /// Allowed values are: [0-10000).
    const EWrongFee: u64 = 1;

    /// For when someone tries to swap in an empty pool.
    const EReservesEmpty: u64 = 2;

    /// For when initial LSP amount is zero.
    const EShareEmpty: u64 = 3;

    /// For when someone attempts to add more liquidity than u128 Math allows.
    const EPoolFull: u64 = 4;

    /// For when supplied Coin is zero.
    const PAIR_ALREADY_REGISTER: u64 = 1009;
    /// The integer scaling setting for fees calculation.
    const FEE_SCALING: u128 = 10000;

    /// The max value that can be held in one of the Balances of
    /// a Pool. U64 MAX / FEE_SCALING
    const MAX_POOL_VALUE: u64 = {
        18446744073709551615 / 10000
    };

    /// Register liquidity pool `X`/`Y`.
    public fun register<X, Y>(coin_x: Coin<X>,
                              coin_y: Coin<Y>,
                              time_obj: &Clock,
                              swap_info: &mut RyuSwap,
                              storage: &mut DaoFeeInfo,
                              ctx: &mut TxContext): Coin<LPCoin<X, Y>> {
        // assert_no_emergency();
        let send_addr = tx_context::sender(ctx);
        let x_amt = coin::value(&coin_x);
        let y_amt = coin::value(&coin_y);

        assert!(coin_helper::is_sorted<X, Y>(), ERR_WRONG_PAIR_ORDERING);
        assert!(!dynamic_field::exists_<String>(&mut swap_info.id, type_name::into_string(type_name::get<LPCoin<X, Y>>())), PAIR_ALREADY_REGISTER);
        assert!(x_amt > 0 && y_amt > 0, EZeroAmount);
        assert!(x_amt < MAX_POOL_VALUE && y_amt < MAX_POOL_VALUE, EPoolFull);

        // Initial share of LSP is the sqrt(a) * sqrt(b)
        let share = math::sqrt(math::mul_to_u128(x_amt, y_amt));
        let lsp_supply = balance::create_supply(LPCoin<X, Y> {});
        let lsp = balance::increase_supply(&mut lsp_supply, share);

        let pool = LiquidityPool<X, Y> {
            id: object::new(ctx),
            coin_x_reserve: coin::into_balance(coin_x),
            coin_y_reserve: coin::into_balance(coin_y),
            last_block_timestamp: 0,
            last_price_x_cumulative: 0,
            last_price_y_cumulative: 0,
            locked: false,
            lsp_supply,
            fee: 30, // 1 - 100 (0.01% - 1%)
            dao_fee: 33, // 0 - 100 (0% - 100%)
        };

        update_oracle<X, Y>(&mut pool, time_obj, x_amt, y_amt);

        dynamic_object_field::add(&mut swap_info.id, type_name::into_string(type_name::get<LPCoin<X, Y>>()), pool);

        dao_fee::register<X, Y>(storage);
        event::emit(PoolCreatedEvent<X, Y> { creator: send_addr });

        // Withdraw those values from reserves
        coin::from_balance(lsp, ctx)
    }

    /// Mint new liquidity coins.
    /// * `coin_x` - coin X to add to liquidity reserves.
    /// * `coin_y` - coin Y to add to liquidity reserves.
    /// Returns LP coins: `Coin<LP<X, Y>>`.
    public fun mint<X, Y>(swap_info: &mut RyuSwap, time_obj: &Clock, coin_x: Coin<X>, coin_y: Coin<Y>, ctx: &mut TxContext): Coin<LPCoin<X, Y>> {
        // assert_no_emergency();

        assert!(coin_helper::is_sorted<X, Y>(), ERR_WRONG_PAIR_ORDERING);
        let pool = dynamic_object_field::borrow_mut<String, LiquidityPool<X, Y>>(&mut swap_info.id, type_name::into_string(type_name::get<LPCoin<X, Y>>()));

        assert!(!pool.locked, ERR_POOL_IS_LOCKED);


        let lp_coins_total = balance::supply_value(&pool.lsp_supply);

        let x_reserve_size = balance::value(&pool.coin_x_reserve);
        let y_reserve_size = balance::value(&pool.coin_y_reserve);

        let bal_x = coin::into_balance(coin_x);
        let bal_y = coin::into_balance(coin_y);

        let x_provided_val = balance::value<X>(&bal_x);
        let y_provided_val = balance::value<Y>(&bal_y);

        let provided_liq = {
            let x_liq = math::mul_div_u128((x_provided_val as u128), (lp_coins_total as u128), (x_reserve_size as u128));
            let y_liq = math::mul_div_u128((y_provided_val as u128), (lp_coins_total as u128), (y_reserve_size as u128));
            if (x_liq < y_liq) {
                x_liq
            } else {
                y_liq
            }
        };

        assert!(provided_liq > 0, ERR_NOT_ENOUGH_LIQUIDITY);

        balance::join(&mut pool.coin_x_reserve, bal_x);
        balance::join(&mut pool.coin_y_reserve, bal_y);

        let lp_coins = balance::increase_supply(&mut pool.lsp_supply, provided_liq);

        update_oracle<X, Y>(pool, time_obj, x_reserve_size, y_reserve_size);

        event::emit(LiquidityAddedEvent<X, Y> {
            added_x_val: x_provided_val,
            added_y_val: y_provided_val,
            lp_tokens_received: provided_liq
        });
        coin::from_balance(lp_coins, ctx)
    }


    /// Burn liquidity coins (LP) and get back X and Y coins from reserves.
    /// * `lp_coins` - LP coins to burn.
    /// Returns both X and Y coins - `(Coin<X>, Coin<Y>)`.
    public fun burn<X, Y>(swap_info: &mut RyuSwap, time_obj: &Clock, lp_coins: Coin<LPCoin<X, Y>>, ctx: &mut TxContext): (Coin<X>, Coin<Y>) {
        assert!(coin_helper::is_sorted<X, Y>(), ERR_WRONG_PAIR_ORDERING);
        let pool = dynamic_object_field::borrow_mut<String, LiquidityPool<X, Y>>(&mut swap_info.id, type_name::into_string(type_name::get<LPCoin<X, Y>>()));
        assert!(!pool.locked, ERR_POOL_IS_LOCKED);

        let burned_lp_coins_val = coin::value(&lp_coins);
        let lp_coins_total = balance::supply_value(&pool.lsp_supply);

        let x_reserve_val = balance::value(&pool.coin_x_reserve);
        let y_reserve_val = balance::value(&pool.coin_y_reserve);

        // Compute x, y coin values for provided lp_coins value
        let x_to_return_val = math::mul_div_u128((burned_lp_coins_val as u128), (x_reserve_val as u128), (lp_coins_total as u128));
        let y_to_return_val = math::mul_div_u128((burned_lp_coins_val as u128), (y_reserve_val as u128), (lp_coins_total as u128));
        assert!(x_to_return_val > 0 && y_to_return_val > 0, ERR_INCORRECT_BURN_VALUES);


        // Withdraw those values from reserves
        update_oracle<X, Y>(pool, time_obj, x_reserve_val, y_reserve_val);
        balance::decrease_supply(&mut pool.lsp_supply, coin::into_balance(lp_coins));

        event::emit(LiquidityRemovedEvent<X, Y> {
            returned_x_val: x_to_return_val,
            returned_y_val: y_to_return_val,
            lp_tokens_burned: burned_lp_coins_val
        });
        (
            coin::take(&mut pool.coin_x_reserve, x_to_return_val, ctx),
            coin::take(&mut pool.coin_y_reserve, y_to_return_val, ctx)
        )
    }

    /// Swap coins (can swap both x and y in the same time).
    /// In the most of situation only X or Y coin argument has value (similar with *_out, only one _out will be non-zero).
    /// Because an user usually exchanges only one coin, yet function allow to exchange both coin.
    /// * `x_in` - X coins to swap.
    /// * `x_out` - expected amount of X coins to get out.
    /// * `y_in` - Y coins to swap.
    /// * `y_out` - expected amount of Y coins to get out.
    /// Returns both exchanged X and Y coins: `(Coin<X>, Coin<Y>)`.
    public fun swap<X, Y>(swap_info: &mut RyuSwap, storage: &mut DaoFeeInfo, time_obj: &Clock,
                          x_in: Coin<X>,
                          x_out: u64,
                          y_in: Coin<Y>,
                          y_out: u64,
                          ctx: &mut TxContext
    ): (Coin<X>, Coin<Y>) {
        // assert_no_emergency();
        assert!(coin_helper::is_sorted<X, Y>(), ERR_WRONG_PAIR_ORDERING);
        let pool = dynamic_object_field::borrow_mut<String, LiquidityPool<X, Y>>(&mut swap_info.id, type_name::into_string(type_name::get<LPCoin<X, Y>>()));
        assert!(!pool.locked, ERR_POOL_IS_LOCKED);
        let x_in_val = coin::value(&x_in);
        let y_in_val = coin::value(&y_in);

        assert!(x_in_val > 0 || y_in_val > 0, ERR_EMPTY_COIN_IN);

        let x_reserve_size = balance::value(&pool.coin_x_reserve);
        let y_reserve_size = balance::value(&pool.coin_y_reserve);

        // Deposit new coins to liquidity pool.
        coin::put(&mut pool.coin_x_reserve, x_in);
        coin::put(&mut pool.coin_y_reserve, y_in);

        // Withdraw expected amount from reserves.
        let x_swapped = coin::take(&mut pool.coin_x_reserve, x_out, ctx);
        let y_swapped = coin::take(&mut pool.coin_y_reserve, y_out, ctx);

        // Confirm that lp_value for the pool hasn't been reduced.
        // For that, we compute lp_value with old reserves and lp_value with reserves after swap is done,
        // and make sure lp_value doesn't decrease
        let (x_res_new_after_fee, y_res_new_after_fee) =
            new_reserves_after_fees_scaled(
                balance::value(&pool.coin_x_reserve),
                balance::value(&pool.coin_y_reserve),
                x_in_val,
                y_in_val,
                pool.fee
            );
        assert_lp_value_is_increased(
            (x_reserve_size as u128),
            (y_reserve_size as u128),
            (x_res_new_after_fee as u128),
            (y_res_new_after_fee as u128),
        );

        split_fee_to_dao(pool, storage, x_in_val, y_in_val);

        update_oracle<X, Y>(pool, time_obj, x_reserve_size, y_reserve_size);

        event::emit(SwapEvent<X, Y> {
            x_in: x_in_val,
            y_in: y_in_val,
            x_out,
            y_out,
        });
        // Return swapped amount.
        (x_swapped, y_swapped)
    }


    // Private functions.

    /// Get reserves after fees.
    /// * `x_reserve` - reserve X.
    /// * `y_reserve` - reserve Y.
    /// * `x_in_val` - amount of X coins added to reserves.
    /// * `y_in_val` - amount of Y coins added to reserves.
    /// * `fee` - amount of fee.
    /// Returns both X and Y reserves after fees.
    fun new_reserves_after_fees_scaled(
        x_reserve: u64,
        y_reserve: u64,
        x_in_val: u64,
        y_in_val: u64,
        fee: u64,
    ): (u128, u128) {
        let x_res_new_after_fee = math::mul_to_u128(x_reserve, FEE_SCALE) - math::mul_to_u128(x_in_val, fee);


        let y_res_new_after_fee = math::mul_to_u128(y_reserve, FEE_SCALE) - math::mul_to_u128(y_in_val, fee);


        (x_res_new_after_fee, y_res_new_after_fee)
    }

    /// Depositing part of fees to DAO Storage.
    /// * `pool` - pool to extract coins.
    /// * `x_in_val` - how much X coins was deposited to pool.
    /// * `y_in_val` - how much Y coins was deposited to pool.
    fun split_fee_to_dao<X, Y>(
        pool: &mut LiquidityPool<X, Y>,
        storage: &mut DaoFeeInfo,
        x_in_val: u64,
        y_in_val: u64
    ) {
        let fee_multiplier = pool.fee;
        let dao_fee = pool.dao_fee;
        // Split dao_fee_multiplier% of fee multiplier of provided coins to the DAOStorage
        //float decimals value util
        let dao_fee_multiplier = if (fee_multiplier * dao_fee % DAO_FEE_SCALE != 0) {
            (fee_multiplier * dao_fee / DAO_FEE_SCALE) + 1
        } else {
            fee_multiplier * dao_fee / DAO_FEE_SCALE
        };
        let dao_x_fee_val = math::mul_div(x_in_val, dao_fee_multiplier, FEE_SCALE);
        let dao_y_fee_val = math::mul_div(y_in_val, dao_fee_multiplier, FEE_SCALE);

        let dao_x_in = balance::split(&mut pool.coin_x_reserve, dao_x_fee_val);
        let dao_y_in = balance::split(&mut pool.coin_y_reserve, dao_y_fee_val);
        dao_fee::deposit<X, Y>(storage, dao_x_in, dao_y_in);
    }

    /// Compute and verify LP value after and before swap, in nutshell, _k function.
    /// * `x_scale` - 10 pow by X coin decimals.
    /// * `y_scale` - 10 pow by Y coin decimals.
    /// * `x_res` - X reserves before swap.
    /// * `y_res` - Y reserves before swap.
    /// * `x_res_with_fees` - X reserves after swap.
    /// * `y_res_with_fees` - Y reserves after swap.
    /// Aborts if swap can't be done.
    fun assert_lp_value_is_increased(
        x_res: u128,
        y_res: u128,
        x_res_with_fees: u128,
        y_res_with_fees: u128,
    ) {
        let lp_value_before_swap = x_res * y_res;
        let lp_value_before_swap_u256 = u256::mul(
            u256::from_u128(lp_value_before_swap),
            u256::from_u64(FEE_SCALE * FEE_SCALE)
        );
        let lp_value_after_swap_and_fee = u256::mul(
            u256::from_u128(x_res_with_fees),
            u256::from_u128(y_res_with_fees),
        );


        let cmp = u256::compare(&lp_value_after_swap_and_fee, &lp_value_before_swap_u256);
        assert!(cmp == 2, ERR_INCORRECT_SWAP);
    }

    /// Update current cumulative prices.
    /// Important: If you want to use the following function take into account prices can be overflowed.
    /// So it's important to use same logic in your math/algo (as Move doesn't allow overflow). See math::overflow_add.
    /// * `pool` - Liquidity pool to update prices.
    /// * `x_reserve` - coin X reserves.
    /// * `y_reserve` - coin Y reserves.
    fun update_oracle<X, Y>(
        pool: &mut LiquidityPool<X, Y>,
        time_obj: &Clock,
        x_reserve: u64,
        y_reserve: u64
    ) {
        let last_block_timestamp = pool.last_block_timestamp;

        let block_timestamp = clock::timestamp_ms(time_obj) / 1000;


        let time_elapsed = ((block_timestamp - last_block_timestamp) as u128);

        if (time_elapsed > 0 && x_reserve != 0 && y_reserve != 0) {
            let last_price_x_cumulative = uq64x64::to_u128(uq64x64::fraction(y_reserve, x_reserve)) * time_elapsed;
            let last_price_y_cumulative = uq64x64::to_u128(uq64x64::fraction(x_reserve, y_reserve)) * time_elapsed;

            pool.last_price_x_cumulative = math::overflow_add(pool.last_price_x_cumulative, last_price_x_cumulative);
            pool.last_price_y_cumulative = math::overflow_add(pool.last_price_y_cumulative, last_price_y_cumulative);

            event::emit(
                OracleUpdatedEvent<X, Y> {
                    last_price_x_cumulative: pool.last_price_x_cumulative,
                    last_price_y_cumulative: pool.last_price_y_cumulative,
                });
        };

        pool.last_block_timestamp = block_timestamp;
    }

    public fun get_lp_total<X, Y>(pool: & LiquidityPool<X, Y>): u64 {
        balance::supply_value(&pool.lsp_supply)
    }

    // Getters.

    /// Check if pool is locked.
    public fun is_pool_locked<X, Y>(pool: &LiquidityPool<X, Y>): bool {
        pool.locked
    }

    /// Get reserves of a pool.
    /// Returns both (X, Y) reserves.
    public fun get_reserves_size<X, Y>(swap_info: &mut RyuSwap): (u64, u64) {
        assert_no_emergency();
        assert!(coin_helper::is_sorted<X, Y>(), ERR_WRONG_PAIR_ORDERING);
        let pool = dynamic_object_field::borrow<String, LiquidityPool<X, Y>>(&mut swap_info.id, type_name::into_string(type_name::get<LPCoin<X, Y>>()));
        let x_reserve = balance::value(&pool.coin_x_reserve);
        let y_reserve = balance::value(&pool.coin_y_reserve);
        (x_reserve, y_reserve)
    }


    public fun get_cumulative_prices<X, Y>(swap_info: &mut RyuSwap): (u128, u128, u64) {
        assert_no_emergency();
        assert!(coin_helper::is_sorted<X, Y>(), ERR_WRONG_PAIR_ORDERING);
        assert!(coin_helper::is_sorted<X, Y>(), ERR_WRONG_PAIR_ORDERING);
        let pool = dynamic_object_field::borrow<String, LiquidityPool<X, Y>>(&mut swap_info.id, type_name::into_string(type_name::get<LPCoin<X, Y>>()));
        let last_price_x_cumulative = *&pool.last_price_x_cumulative;
        let last_price_y_cumulative = *&pool.last_price_y_cumulative;
        let last_block_timestamp = pool.last_block_timestamp;

        (last_price_x_cumulative, last_price_y_cumulative, last_block_timestamp)
    }


    /// Check if liquidity pool exists.
    public fun is_pool_exists<X, Y>(swap_info: &mut RyuSwap): bool {
        assert!(coin_helper::is_sorted<X, Y>(), ERR_WRONG_PAIR_ORDERING);
        dynamic_object_field::exists_<String>(&mut swap_info.id, type_name::into_string(type_name::get<LPCoin<X, Y>>()))
    }

    /// Get fee for specific pool together with denominator (numerator, denominator).
    public fun get_fees_config<X, Y>(swap_info: &mut RyuSwap): (u64, u64) {
        (get_fee<X, Y>(swap_info), FEE_SCALE)
    }

    /// Get fee for specific pool.
    public fun get_fee<X, Y>(swap_info: &mut RyuSwap): u64 {
        assert!(coin_helper::is_sorted<X, Y>(), ERR_WRONG_PAIR_ORDERING);
        let pool = dynamic_object_field::borrow<String, LiquidityPool<X, Y>>(&mut swap_info.id, type_name::into_string(type_name::get<LPCoin<X, Y>>()));
        pool.fee
    }

    /// Set fee for specific pool.
    public entry fun set_fee<X, Y>(swap_info: &mut RyuSwap, pool: &mut LiquidityPool<X, Y>, config: &Config, fee: u64, ctx: &mut TxContext) {
        assert!(coin_helper::is_sorted<X, Y>(), ERR_WRONG_PAIR_ORDERING);
        assert!(dynamic_field::exists_<String>(&mut swap_info.id, type_name::into_string(type_name::get<LPCoin<X, Y>>())), ERR_POOL_DOES_NOT_EXIST);
        assert!(!pool.locked, ERR_POOL_IS_LOCKED);
        assert!(tx_context::sender(ctx) == config::get_fee_admin(config), ERR_NOT_ADMIN);

        config::assert_valid_fee(fee);

        pool.fee = fee;

        event::emit(UpdateFeeEvent<X, Y> { new_fee: fee });
    }

    /// Get DAO fee for specific pool together with denominator (numerator, denominator).
    public fun get_dao_fees_config<X, Y>(swap_info: &mut RyuSwap): (u64, u64) {
        (get_dao_fee<X, Y>(swap_info), DAO_FEE_SCALE)
    }

    /// Get DAO fee for specific pool.
    public fun get_dao_fee<X, Y>(swap_info: &mut RyuSwap): u64 {
        assert!(coin_helper::is_sorted<X, Y>(), ERR_WRONG_PAIR_ORDERING);
        let pool = dynamic_object_field::borrow<String, LiquidityPool<X, Y>>(&mut swap_info.id, type_name::into_string(type_name::get<LPCoin<X, Y>>()));
        pool.dao_fee
    }

    /// Set DAO fee for specific pool.
    public entry fun set_dao_fee<X, Y>(swap_info: &mut RyuSwap, pool: &mut LiquidityPool<X, Y>, config: &Config, dao_fee: u64, ctx: &mut TxContext) {
        assert!(coin_helper::is_sorted<X, Y>(), ERR_WRONG_PAIR_ORDERING);
        assert!(dynamic_field::exists_<String>(&mut swap_info.id, type_name::into_string(type_name::get<LPCoin<X, Y>>())), ERR_POOL_DOES_NOT_EXIST);
        assert!(!pool.locked, ERR_POOL_IS_LOCKED);
        assert!(tx_context::sender(ctx) == config::get_fee_admin(config), ERR_NOT_ADMIN);

        config::assert_valid_dao_fee(dao_fee);

        pool.dao_fee = dao_fee;

        event::emit(UpdateDAOFeeEvent<X, Y> { new_fee: dao_fee });
    }

    /// Would abort if currently paused.
    public fun assert_no_emergency() {
        // assert!(!is_emergency(), ERR_EMERGENCY);
    }

    ///create event
    struct PoolCreatedEvent<phantom X, phantom Y> has drop, copy {
        creator: address,
    }

    struct LiquidityAddedEvent<phantom X, phantom Y> has copy, drop {
        added_x_val: u64,
        added_y_val: u64,
        lp_tokens_received: u64,
    }

    struct LiquidityRemovedEvent<phantom X, phantom Y> has copy, drop {
        returned_x_val: u64,
        returned_y_val: u64,
        lp_tokens_burned: u64,
    }

    struct SwapEvent<phantom X, phantom Y> has copy, drop {
        x_in: u64,
        x_out: u64,
        y_in: u64,
        y_out: u64,
    }

    struct FlashloanEvent<phantom X, phantom Y> has copy, drop {
        x_in: u64,
        x_out: u64,
        y_in: u64,
        y_out: u64,
    }

    struct OracleUpdatedEvent<phantom X, phantom Y> has copy, drop {
        last_price_x_cumulative: u128,
        last_price_y_cumulative: u128,
    }

    struct UpdateFeeEvent<phantom X, phantom Y> has copy, drop {
        new_fee: u64,
    }

    struct UpdateDAOFeeEvent<phantom X, phantom Y> has copy, drop {
        new_fee: u64,
    }


}
