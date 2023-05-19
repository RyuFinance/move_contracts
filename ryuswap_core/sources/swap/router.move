/// Router  for Liquidity Pool, similar to Uniswap router.
module ryufinance::router {
    use ryulib::coin_helper::{Self};
    use ryulib::math;
    use ryufinance::swap;
    use ryufinance::swap::{LiquidityPool, LPCoin, RyuSwap};
    use sui::coin::Coin;
    use sui::coin;
    use ryufinance::dao_fee::DaoFeeInfo;
    use sui::tx_context::TxContext;
    use sui::tx_context;
    use sui::transfer;
    use std::vector;
    use sui::clock::Clock;

    // Errors codes.

    ///
    const ERRWrongFee: u64 = 1;
    const ERRInput: u64 = 2;
    const ErrCoinArrLength: u64 = 3;
    const ErrCoinInVal: u64 = 4;

    /// Wrong amount used.
    const ERR_WRONG_AMOUNT: u64 = 200;
    /// Wrong reserve used.
    const ERR_WRONG_RESERVE: u64 = 201;
    /// Wrong order of coin parameters.
    const ERR_WRONG_COIN_ORDER: u64 = 208;
    /// Insufficient amount in Y reserves.
    const ERR_INSUFFICIENT_Y_AMOUNT: u64 = 202;
    /// Insufficient amount in X reserves.
    const ERR_INSUFFICIENT_X_AMOUNT: u64 = 203;
    /// Overlimit of X coins to swap.
    const ERR_OVERLIMIT_X: u64 = 204;
    /// Amount out less than minimum.
    const ERR_COIN_OUT_NUM_LESS_THAN_EXPECTED_MINIMUM: u64 = 205;
    /// Needed amount in great than maximum.
    const ERR_COIN_VAL_MAX_LESS_THAN_NEEDED: u64 = 206;
    /// Marks the unreachable place in code
    const ERR_UNREACHABLE: u64 = 207;
    /// Provided coins amount cannot be converted without the overflow at the current price
    const ERR_COIN_CONVERSION_OVERFLOW: u64 = 208;

    const ERR_COIN_CANNOT_EQUAL: u64 = 209;

    // Consts
    const MAX_U64: u128 = 18446744073709551615;

    // Public functions.

    /// Register new liquidity pool for `X`/`Y` pair on signer address with `LP` coin.
    ///
    /// Note: X, Y generic coin parameters must be sorted.
    public entry fun register_lp<X, Y>(
        coin_x_arr: vector<Coin<X>>,
        coin_x_in: u64,
        coin_y_arr: vector<Coin<Y>>,
        coin_y_in: u64,
        time_obj: &Clock,
        swap_info: &mut RyuSwap,
        storage: &mut DaoFeeInfo,
        ctx: &mut TxContext, ) {
        assert!(coin_helper::is_sorted<X, Y>(), ERR_WRONG_COIN_ORDER);
        let coin_x = handle_coin_obj(coin_x_arr, coin_x_in, ctx);
        let coin_y = handle_coin_obj(coin_y_arr, coin_y_in, ctx);
        let account_addr = tx_context::sender(ctx);
        let lp_coins = swap::register<X, Y>(coin_x, coin_y, time_obj, swap_info, storage, ctx);
        transfer::public_transfer(lp_coins, account_addr);
    }

    /// Add liquidity to pool `X`/`Y` with rationality checks.
    /// * `coin_x` - coin X to add as liquidity.
    /// * `min_coin_x_val` - minimum amount of coin X to add as liquidity.
    /// * `coin_y` - coin Y to add as liquidity.
    /// * `min_coin_y_val` - minimum amount of coin Y to add as liquidity.
    /// Returns remainders of coins X and Y, and LP coins: `(Coin<X>, Coin<Y>, Coin<LP<X, Y>>)`.
    ///
    /// Note: X, Y generic coin parameters must be sorted.
    public entry fun add_lp<X, Y>(
        coin_x_arr: vector<Coin<X>>,
        coin_x_in: u64,
        coin_x_val_min: u64,
        coin_y_arr: vector<Coin<Y>>,
        coin_y_in: u64,
        coin_y_val_min: u64,
        swap_info: &mut RyuSwap,
        time_obj: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(coin_helper::is_sorted<X, Y>(), ERR_WRONG_COIN_ORDER);


        let coin_x = handle_coin_obj(coin_x_arr, coin_x_in, ctx);
        let coin_y = handle_coin_obj(coin_y_arr, coin_y_in, ctx);
        let coin_x_val = coin::value(&coin_x);
        let coin_y_val = coin::value(&coin_y);

        assert!(coin_x_val >= coin_x_val_min, ERR_INSUFFICIENT_X_AMOUNT);
        assert!(coin_y_val >= coin_y_val_min, ERR_INSUFFICIENT_Y_AMOUNT);

        let (optimal_x, optimal_y) =
            calc_optimal_coin_values<X, Y>(
                swap_info,
                coin_x_val,
                coin_y_val,
                coin_x_val_min,
                coin_y_val_min
            );

        let coin_x_opt = coin::split(&mut coin_x, optimal_x, ctx);
        let coin_y_opt = coin::split(&mut coin_y, optimal_y, ctx);

        let lp_coins = swap::mint<X, Y>(swap_info, time_obj, coin_x_opt, coin_y_opt, ctx);

        let account_addr = tx_context::sender(ctx);


        if (coin::value(&coin_x) == 0) {
            coin::destroy_zero(coin_x);
        }else {
            transfer::public_transfer(coin_x, account_addr);
        };

        if (coin::value(&coin_y) == 0) {
            coin::destroy_zero(coin_y);
        }else {
            transfer::public_transfer(coin_y, account_addr);
        };
        transfer::public_transfer(lp_coins, account_addr);
    }

    /// Burn liquidity coins `LP` and get coins `X` and `Y` back.
    /// * `lp_coins` - `LP` coins to burn.
    /// * `min_x_out_val` - minimum amount of `X` coins must be out.
    /// * `min_y_out_val` - minimum amount of `Y` coins must be out.
    /// Returns both `Coin<X>` and `Coin<Y>`: `(Coin<X>, Coin<Y>)`.
    ///
    /// Note: X, Y generic coin parameters should be sorted.
    public entry fun remove_lp<X, Y>(
        lp_coins_arr: vector<Coin<LPCoin<X, Y>>>,
        lp_coins_in: u64,
        min_x_out_val: u64,
        min_y_out_val: u64,
        swap_info: &mut RyuSwap,
        time_obj: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(coin_helper::is_sorted<X, Y>(), ERR_WRONG_COIN_ORDER);

        let lp_coins = handle_lpcoin_obj(lp_coins_arr, lp_coins_in, ctx);

        let (coin_x, coin_y) = swap::burn<X, Y>(swap_info, time_obj, lp_coins, ctx);

        assert!(
            coin::value(&coin_x) >= min_x_out_val,
            ERR_COIN_OUT_NUM_LESS_THAN_EXPECTED_MINIMUM
        );
        assert!(
            coin::value(&coin_y) >= min_y_out_val,
            ERR_COIN_OUT_NUM_LESS_THAN_EXPECTED_MINIMUM
        );
        let account_addr = tx_context::sender(ctx);
        transfer::public_transfer(coin_x, account_addr);
        transfer::public_transfer(coin_y, account_addr);
    }


    public entry fun swap_exact_coin_for_coin<X, Y>(
        coin_in_arr: vector<Coin<X>>,
        coin_in_val: u64,
        coin_out_min_val: u64,
        swap_info: &mut RyuSwap,
        storage: &mut DaoFeeInfo,
        time_obj: &Clock,
        ctx: &mut TxContext
    ) {
        let coin_in = handle_coin_obj(coin_in_arr, coin_in_val, ctx);

        let (reserve_x, reserve_y) = get_reserves_size<X, Y>(swap_info);
        let (fee_pct, fee_scale) = get_fees_config<X, Y>(swap_info);
        let coin_in_val = coin::value(&coin_in);
        let account_addr = tx_context::sender(ctx);

        let coin_out_val = get_amount_out<X, Y>(reserve_x, reserve_y, fee_pct, fee_scale, coin_in_val);
        assert!(
            coin_out_val >= coin_out_min_val,
            ERR_COIN_OUT_NUM_LESS_THAN_EXPECTED_MINIMUM,
        );

        let coin_out = swap_coin_for_coin_unchecked<X, Y>(swap_info, storage, time_obj, coin_in, coin_out_val, ctx);
        transfer::public_transfer(coin_out, account_addr);
    }


    public entry fun swap_coin_for_exact_coin<X, Y>(
        coin_in_arr: vector<Coin<X>>,
        coin_in_val: u64,
        coin_out_val: u64,
        swap_info: &mut RyuSwap,
        storage: &mut DaoFeeInfo,
        time_obj: &Clock,
        ctx: &mut TxContext
    ) {
        let (reserve_x, reserve_y) = get_reserves_size<X, Y>(swap_info);
        let (fee_pct, fee_scale) = get_fees_config<X, Y>(swap_info);
        let expectIn = get_amount_in<X, Y>(reserve_x, reserve_y, fee_pct, fee_scale, coin_out_val);
        let coin_max_in = handle_coin_obj(coin_in_arr, coin_in_val, ctx);
        let account_addr = tx_context::sender(ctx);

        let coin_val_max = coin::value(&coin_max_in);
        assert!(
            expectIn <= coin_val_max,
            ERR_COIN_VAL_MAX_LESS_THAN_NEEDED
        );
        let coin_in;
        let coin_out;
        if (expectIn < coin_val_max) {
            coin_in = coin::split(&mut coin_max_in, expectIn, ctx);
            transfer::public_transfer(coin_max_in, account_addr);
            coin_out = swap_coin_for_coin_unchecked<X, Y>(swap_info, storage, time_obj, coin_in, coin_out_val, ctx);
        }else {
            coin_out = swap_coin_for_coin_unchecked<X, Y>(swap_info, storage, time_obj, coin_max_in, coin_out_val, ctx);
        };
        // let coin_out = swap_coin_for_coin_unchecked_with_swap_fee<X, Y>(swap_info,storage,time_obj,pool,coin_in, coin_out_val1,ctx);
        transfer::public_transfer(coin_out, account_addr);
    }

    /// Returns `Coin<Y>`.
    fun swap_coin_for_coin_unchecked<X, Y>(
        swap_info: &mut RyuSwap,
        storage: &mut DaoFeeInfo,
        time_obj: &Clock,
        coin_in: Coin<X>,
        coin_out_val: u64,
        ctx: &mut TxContext
    ): Coin<Y> {
        let (zero, coin_out);
        if (coin_helper::is_sorted<X, Y>()) {
            (zero, coin_out) = swap::swap<X, Y>(swap_info, storage, time_obj, coin_in, 0, coin::zero(ctx), coin_out_val, ctx);
        } else {
            (coin_out, zero) = swap::swap<Y, X>(swap_info, storage, time_obj, coin::zero(ctx), coin_out_val, coin_in, 0, ctx);
        };
        coin::destroy_zero(zero);
        coin_out
    }


    fun handle_coin_obj<T>(coin_in_arr: vector<Coin<T>>, coin_in_val: u64, ctx: &mut TxContext): Coin<T> {
        assert!(vector::length(&coin_in_arr) > 0, ErrCoinArrLength);
        assert!(coin_in_val > 0, ErrCoinInVal);
        let new_coin = coin::zero<T>(ctx);
        let amount = 0;
        while (vector::length(&coin_in_arr) > 0) {
            let coin_in_item = vector::pop_back(&mut coin_in_arr);
            if (amount < coin_in_val) {
                let item_amount = coin::value(&coin_in_item);
                // amount == 100 item_amount == 30 coin_in_val=110
                if ((item_amount + amount) <= coin_in_val) {
                    coin::join(&mut new_coin, coin_in_item);
                    amount = item_amount + amount;
                }else {
                    let need_pay_amount = coin_in_val - amount;
                    let coin_join = coin::split(&mut coin_in_item, need_pay_amount, ctx);
                    coin::join(&mut new_coin, coin_join);
                    amount = amount + need_pay_amount;
                    transfer::public_transfer(coin_in_item, tx_context::sender(ctx))
                }
            }else {
                transfer::public_transfer(coin_in_item, tx_context::sender(ctx))
            }
        };
        vector::destroy_empty(coin_in_arr);
        assert!(coin::value(&new_coin) == coin_in_val, ERRInput);
        new_coin
    }

    fun handle_lpcoin_obj<X, Y>(coin_in_arr: vector<Coin<LPCoin<X, Y>>>, coin_in_val: u64, ctx: &mut TxContext): Coin<LPCoin<X, Y>> {
        assert!(vector::length(&coin_in_arr) > 0, ErrCoinArrLength);
        assert!(coin_in_val > 0, ErrCoinInVal);
        let new_coin = coin::zero<LPCoin<X, Y>>(ctx);
        let amount = 0;
        while (vector::length(&coin_in_arr) > 0) {
            let coin_in_item = vector::pop_back(&mut coin_in_arr);
            if (amount < coin_in_val) {
                let item_amount = coin::value(&coin_in_item);
                // amount == 100 item_amount == 30 coin_in_val=110
                if ((item_amount + amount) <= coin_in_val) {
                    coin::join(&mut new_coin, coin_in_item);
                    amount = item_amount + amount;
                }else {
                    let need_pay_amount = coin_in_val - amount;
                    let coin_join = coin::split(&mut coin_in_item, need_pay_amount, ctx);
                    coin::join(&mut new_coin, coin_join);
                    amount = amount + need_pay_amount;
                    transfer::public_transfer(coin_in_item, tx_context::sender(ctx))
                }
            }else {
                transfer::public_transfer(coin_in_item, tx_context::sender(ctx))
            }
        };
        vector::destroy_empty(coin_in_arr);
        assert!(coin::value(&new_coin) == coin_in_val, ERRInput);
        new_coin
    }

    /// Get current cumulative prices in liquidity pool `X`/`Y`.
    /// Returns (X price, Y price, block_timestamp).
    public fun get_cumulative_prices<X, Y>(swap_info: &mut RyuSwap): (u128, u128, u64) {
        if (coin_helper::is_sorted<X, Y>()) {
            swap::get_cumulative_prices<X, Y>(swap_info)
        }else {
            swap::get_cumulative_prices<Y, X>(swap_info)
        }
    }

    /// Get reserves of liquidity pool (`X` and `Y`).
    /// Returns current reserves (`X`, `Y`).
    public fun get_reserves_size<X, Y>(swap_info: &mut RyuSwap): (u64, u64) {
        if (coin_helper::is_sorted<X, Y>()) {
            swap::get_reserves_size<X, Y>(swap_info)
        }else {
            let (y_res, x_res) = swap::get_reserves_size<Y, X>(swap_info);
            (x_res, y_res)
        }
    }

    /// Get fee for specific pool together with denominator (numerator, denominator).
    public fun get_fees_config<X, Y>(swap_info: &mut RyuSwap): (u64, u64) {
        if (coin_helper::is_sorted<X, Y>()) {
            swap::get_fees_config<X, Y>(swap_info)
        }else {
            swap::get_fees_config<Y, X>(swap_info)
        }
    }

    /// Get fee for specific pool.
    public fun get_fee<X, Y>(swap_info: &mut RyuSwap): u64 {
        if (coin_helper::is_sorted<X, Y>()) {
            swap::get_fee<X, Y>(swap_info)
        }else {
            swap::get_fee<Y, X>(swap_info)
        }
    }

    /// Get DAO fee for specific pool together with denominator (numerator, denominator).
    public fun get_dao_fees_config<X, Y>(swap_info: &mut RyuSwap): (u64, u64) {
        if (coin_helper::is_sorted<X, Y>()) {
            swap::get_dao_fees_config<X, Y>(swap_info)
        }else {
            swap::get_dao_fees_config<Y, X>(swap_info)
        }
    }

    /// Get DAO fee for specific pool.
    public fun get_dao_fee<X, Y>(swap_info: &mut RyuSwap): u64 {
        if (coin_helper::is_sorted<X, Y>()) {
            swap::get_dao_fee<X, Y>(swap_info)
        }else {
            swap::get_dao_fee<Y, X>(swap_info)
        }
    }

    /// Check swap for pair `X` and `Y` exists.
    /// If pool exists returns true, otherwise false.
    public fun is_swap_exists<X, Y>(swap_info: &mut RyuSwap): bool {
        if (coin_helper::is_sorted<X, Y>()) {
            swap::is_pool_exists<X, Y>(swap_info)
        } else {
            swap::is_pool_exists<Y, X>(swap_info)
        }
    }

    // Math.

    /// Calculate optimal amounts of `X`, `Y` coins to add as a new liquidity.
    /// * `x_desired` - provided value of coins `X`.
    /// * `y_desired` - provided value of coins `Y`.
    /// * `x_min` - minimum of coins X expected.
    /// * `y_min` - minimum of coins Y expected.
    /// Returns both `X` and `Y` coins amounts.
    public fun calc_optimal_coin_values<X, Y>(swap_info: &mut RyuSwap,
                                              x_desired: u64,
                                              y_desired: u64,
                                              x_min: u64,
                                              y_min: u64
    ): (u64, u64) {
        //,pool:&mut LiquidityPool<X, Y>

        let (reserves_x, reserves_y) = get_reserves_size<X, Y>(swap_info);

        if (reserves_x == 0 && reserves_y == 0) {
            return (x_desired, y_desired)
        } else {
            let y_returned = convert_with_current_price(x_desired, reserves_x, reserves_y);
            if (y_returned <= y_desired) {
                // amount of `y` received from `x_desired` on a current price is less than `y_desired`
                assert!(y_returned >= y_min, ERR_INSUFFICIENT_Y_AMOUNT);
                return (x_desired, y_returned)
            } else {
                // not enough in `y_desired`, use it as a cap
                let x_returned = convert_with_current_price(y_desired, reserves_y, reserves_x);
                // ERR_OVERLIMIT_X should never occur here, added just in case
                assert!(x_returned <= x_desired, ERR_OVERLIMIT_X);
                assert!(x_returned >= x_min, ERR_INSUFFICIENT_X_AMOUNT);
                return (x_returned, y_desired)
            }
        }
    }

    /// Return amount of liquidity (LP) need for `coin_in`.
    /// * `coin_in` - amount to swap.
    /// * `reserve_in` - reserves of coin to swap.
    /// * `reserve_out` - reserves of coin to get.
    public fun convert_with_current_price(coin_in: u64, reserve_in: u64, reserve_out: u64): u64 {
        assert!(coin_in > 0, ERR_WRONG_AMOUNT);
        assert!(reserve_in > 0 && reserve_out > 0, ERR_WRONG_RESERVE);

        let res = (coin_in as u128) * (reserve_out as u128) / (reserve_in as u128);
        assert!(res <= MAX_U64, ERR_COIN_CONVERSION_OVERFLOW);
        (res as u64)
    }

    /// Convert `LP` coins to `X` and `Y` coins, useful to calculate amount the user recieve after removing liquidity.
    /// * `lp_to_burn_val` - amount of `LP` coins to burn.
    /// Returns both `X` and `Y` coins amounts.
    public fun get_reserves_for_lp_coins<X, Y>(swap_info: &mut RyuSwap, pool: &mut LiquidityPool<X, Y>,
                                               lp_to_burn_val: u64
    ): (u64, u64) {
        let (x_reserve, y_reserve) = get_reserves_size<X, Y>(swap_info);
        let lp_coins_total = swap::get_lp_total(pool);

        let x_to_return_val = math::mul_div_u128((lp_to_burn_val as u128), (x_reserve as u128), (lp_coins_total as u128));
        let y_to_return_val = math::mul_div_u128((lp_to_burn_val as u128), (y_reserve as u128), (lp_coins_total as u128));

        assert!(x_to_return_val > 0 && y_to_return_val > 0, ERR_WRONG_AMOUNT);

        (x_to_return_val, y_to_return_val)
    }


    public fun get_amount_out<X, Y>(reserve_x: u64, reserve_y: u64, fee_pct: u64, fee_scale: u64, amount_in: u64): u64 {

        let amount_out = get_coin_out_with_fees<X, Y>(
            fee_pct,
            fee_scale,
            amount_in,
            reserve_x,
            reserve_y,
        );
        amount_out
    }


    public fun get_amount_in<X, Y>(reserve_x: u64, reserve_y: u64, fee_pct: u64, fee_scale: u64, amount_out: u64): u64 {
        let amount_in = get_coin_in_with_fees<X, Y>(
            fee_pct,
            fee_scale,
            amount_out,
            reserve_y,
            reserve_x,
        );
        amount_in
    }

    // Private functions (contains part of math).

    /// Get coin amount out by passing amount in (include fees). Pass all data manually.
    /// * `coin_in` - exactly amount of coins to swap.
    /// * `reserve_in` - reserves of coin we are going to swap.
    /// * `reserve_out` - reserves of coin we are going to get.
    /// * `scale_in` - 10 pow by decimals amount of coin we going to swap.
    /// * `scale_out` - 10 pow by decimals amount of coin we going to get.
    /// Returns amount of coins out after swap.
    fun get_coin_out_with_fees<X, Y>(
        fee_pct: u64,
        fee_scale: u64,
        coin_in: u64,
        reserve_in: u64,
        reserve_out: u64,
    ): u64 {
        // let (fee_pct, fee_scale) = get_fees_config(swap_info,pool);
        let fee_multiplier = fee_scale - fee_pct;

        let reserve_out_u128 = (reserve_out as u128);


        let coin_in_val_after_fees = math::mul_to_u128(coin_in, fee_multiplier);
        let new_reserve_in = math::mul_to_u128(reserve_in, fee_scale) + coin_in_val_after_fees;

        // Multiply coin_in by the current exchange rate:
        // current_exchange_rate = reserve_out / reserve_in
        // amount_in_after_fees * current_exchange_rate -> amount_out
        math::mul_div_u128(coin_in_val_after_fees,
            reserve_out_u128,
            new_reserve_in)
    }


    fun get_coin_in_with_fees<X, Y>(
        fee_pct: u64,
        fee_scale: u64,
        coin_out: u64,
        reserve_out: u64,
        reserve_in: u64,
    ): u64 {
        assert!(reserve_out > coin_out, ERR_INSUFFICIENT_Y_AMOUNT);

        let fee_multiplier = fee_scale - fee_pct;

        let coin_out_u128 = (coin_out as u128);
        let reserve_in_u128 = (reserve_in as u128);
        let reserve_out_u128 = (reserve_out as u128);


        let new_reserves_out = (reserve_out_u128 - coin_out_u128) * (fee_multiplier as u128);

        // coin_out * reserve_in * fee_scale / new reserves out
        let coin_in = math::mul_div_u128(
            coin_out_u128,
            reserve_in_u128 * (fee_scale as u128),
            new_reserves_out
        ) + 1;
        coin_in
    }


}
