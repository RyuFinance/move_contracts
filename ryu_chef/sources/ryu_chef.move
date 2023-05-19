module ryuchef::ryu_chef {

    use std::vector;
    use std::type_name;
    use sui::event;
    use sui::object::UID;
    use sui::tx_context::TxContext;
    use sui::tx_context;
    use sui::coin;
    use ryucoin::ryu::{Self, AdminCap, RYUInfo, MintCap, RYU};
    use sui::object;

    use sui::transfer;
    use sui::coin::Coin;
    use sui::dynamic_field;
    use sui::dynamic_object_field;
    use std::ascii::String;

    use sui::clock::Clock;
    use sui::clock;


    const ACCOUNT_FORBIDDEN: u64 = 1001;
    const TOKEN_NOT_EXIST: u64 = 1002;
    const TOKEN_ALREADY_EXIST: u64 = 1003;
    const INSUFFICIENT_AMOUNT: u64 = 1004;
    const WAIT_FOR_NEW_BLOCK: u64 = 1005;
    ///user already register pool
    const ALREADY_REG_POOL: u64 = 1006;

    const ERRInput: u64 = 1007;
    const ErrCoinArrLength: u64 = 1008;
    const ErrCoinInVal: u64 = 1009;
    const ErrZERO: u64 = 1010;

    const ACC_RYU_PRECISION: u128 = 1000000000000;
    // 1e12
    const DEPLOYER: address = @dao_admin;


    struct DepositEvent has copy, drop {
        sender_address: address,
        coin_name: String,
        reward: u64,
        amount: u64,
    }

    struct WithdrawEvent has copy, drop {
        sender_address: address,
        coin_name: String,
        reward: u64,
        amount: u64,
    }


    // set event data
    struct SetEvent has copy, drop {
        coin_name: String,
        alloc_point: u64,
    }

    // add event data
    struct AddEvent has copy, drop {
        coin_name: String,
        alloc_point: u64,
    }

    // info of each user, store at user's address
    struct UserInfo<phantom CoinType> has key, store {
        id: UID,
        amount: u64,
        // `amount` LP coin amount the user has provided.
        reward_debt: u128,
        // Reward debt. See explanation below.
    }

    // info of each pool, store at deployer's address
    struct PoolInfo<phantom CoinType> has key, store {
        id: UID,
        coin_reserve: Coin<CoinType>,
        coin_reward: Coin<RYU>,
        acc_RYU_per_share: u128,
        // times ACC_RYU_PRECISION
        last_reward_timestamp: u64,
        alloc_point: u64,
    }

    //TODO one time init
    struct MasterChefData has key {
        id: UID,
        ryu_mint_cap: MintCap,
        total_alloc_point: u64,
        admin_address: address,
        start_timestamp: u64,
        per_second_RYU: u128,
        pool_list: vector<address>,
    }


    // initialize
    public entry fun initialize(ac: &mut AdminCap, clock_obj: &Clock, ctx: &mut TxContext) {
        let addr = tx_context::sender(ctx);
        assert!(addr == @dao_admin, ACCOUNT_FORBIDDEN);
        let chef_id = object::new(ctx);
        // create resource account
        let mint_cap = ryu::set_new_role(ac, &mut chef_id, 1000000000000000000);
        let admin_addr = tx_context::sender(ctx);
        let chef = MasterChefData {
            id: chef_id,
            ryu_mint_cap: mint_cap,
            total_alloc_point: 0,
            admin_address: admin_addr,
            start_timestamp: get_current_timestamp(clock_obj),
            per_second_RYU: 88000000,
            pool_list: vector::empty(),
        };

        transfer::share_object(chef);
    }

    // Deposit LP coins to MC for RYU allocation.
    public entry fun first_deposit<CoinType>(
        coin_in_arr: vector<Coin<CoinType>>,
        coin_in_val: u64,
        clock_obj: &Clock,
        ryu_info: &mut RYUInfo,
        mc_data: &mut MasterChefData,
        ctx: &mut TxContext
    ) {
        let acc_addr = tx_context::sender(ctx);
        assert!(dynamic_object_field::exists_with_type<String, PoolInfo<CoinType>>(&mut mc_data.id, type_name::into_string(type_name::get<CoinType>())), TOKEN_NOT_EXIST);
        let pool = dynamic_object_field::borrow_mut<String, PoolInfo<CoinType>>(&mut mc_data.id, type_name::into_string(type_name::get<CoinType>()));

        assert!(!dynamic_field::exists_with_type<address, address>(&mut pool.id, acc_addr), ALREADY_REG_POOL);
        let user_info_obj = object::new(ctx);
        let user_obj_addr = object::uid_to_address(&user_info_obj);
        dynamic_field::add(&mut pool.id, acc_addr, user_obj_addr);

        let user_info = UserInfo<CoinType> {
            id: user_info_obj,
            amount: 0,
            reward_debt: 0,
        };
        deposit(coin_in_arr, coin_in_val, clock_obj, ryu_info, mc_data, &mut user_info, ctx);
        transfer::transfer(user_info, acc_addr);
    }

    // Deposit LP coins to MC for RYU allocation.
    public entry fun deposit<CoinType>(
        coin_in_arr: vector<Coin<CoinType>>,
        coin_in_val: u64,
        clock_obj: &Clock,
        ryu_info: &mut RYUInfo,
        mc_data: &mut MasterChefData,
        user_info: &mut UserInfo<CoinType>,
        ctx: &mut TxContext
    ) {
        update_pool<CoinType>(clock_obj, ryu_info, mc_data, ctx);

        assert!(dynamic_object_field::exists_with_type<String, PoolInfo<CoinType>>(&mut mc_data.id, type_name::into_string(type_name::get<CoinType>())), TOKEN_NOT_EXIST);
        let pool = dynamic_object_field::borrow_mut<String, PoolInfo<CoinType>>(&mut mc_data.id, type_name::into_string(type_name::get<CoinType>()));

        if (coin_in_val == 0) {
            vector::destroy_empty(coin_in_arr);
        }else {
            let deposit_coin = handle_coin_obj(coin_in_arr, coin_in_val, ctx);
            coin::join(&mut pool.coin_reserve, deposit_coin);
        };

        let acc_addr = tx_context::sender(ctx);
        let pending = 0;
        // exist user, check acc
        if (user_info.amount > 0) {
            pending = (user_info.amount as u128) * pool.acc_RYU_per_share / ACC_RYU_PRECISION - user_info.reward_debt;
            let reward = coin::split(&mut pool.coin_reward, (pending as u64), ctx);
            transfer::public_transfer(reward, acc_addr);
        };
        user_info.amount = user_info.amount + coin_in_val;
        user_info.reward_debt = (user_info.amount as u128) * pool.acc_RYU_per_share / ACC_RYU_PRECISION;


        event::emit(DepositEvent {
            sender_address: acc_addr,
            coin_name: type_name::into_string(type_name::get<CoinType>()),
            reward: (pending as u64),
            amount: coin_in_val,
        });
    }


    // harvest RYU .
    public entry fun harvest<CoinType>(
        clock_obj: &Clock,
        ryu_info: &mut RYUInfo,
        mc_data: &mut MasterChefData,
        user_info: &mut UserInfo<CoinType>,
        ctx: &mut TxContext
    ) {
        deposit(vector::empty(), 0, clock_obj, ryu_info, mc_data, user_info, ctx);
    }


    // Withdraw LP coins from MC.
    public entry fun withdraw<CoinType>(
        amount: u64,
        clock_obj: &Clock,
        ryu_info: &mut RYUInfo,
        mc_data: &mut MasterChefData,
        user_info: &mut UserInfo<CoinType>,
        ctx: &mut TxContext
    ) {
        update_pool<CoinType>(clock_obj, ryu_info, mc_data, ctx);

        assert!(dynamic_object_field::exists_with_type<String, PoolInfo<CoinType>>(&mut mc_data.id, type_name::into_string(type_name::get<CoinType>())), TOKEN_NOT_EXIST);
        let pool = dynamic_object_field::borrow_mut<String, PoolInfo<CoinType>>(&mut mc_data.id, type_name::into_string(type_name::get<CoinType>()));

        let acc_addr = tx_context::sender(ctx);
        assert!(user_info.amount >= amount, INSUFFICIENT_AMOUNT);
        assert!(amount > 0, ErrZERO);

        let pending = 0;
        // exist user, check acc
        if (user_info.amount > 0) {
            pending = (user_info.amount as u128) * pool.acc_RYU_per_share / ACC_RYU_PRECISION - user_info.reward_debt;
            let reward = coin::split(&mut pool.coin_reward, (pending as u64), ctx);
            transfer::public_transfer(reward, acc_addr);
        };
        user_info.amount = user_info.amount - amount;
        user_info.reward_debt = (user_info.amount as u128) * pool.acc_RYU_per_share / ACC_RYU_PRECISION;

        let withdraw_coin = coin::split<CoinType>(&mut pool.coin_reserve, amount, ctx);
        transfer::public_transfer(withdraw_coin, acc_addr);

        // event
        event::emit(WithdrawEvent {
            sender_address: acc_addr,
            coin_name: type_name::into_string(type_name::get<CoinType>()),
            reward: (pending as u64),
            amount,
        });
    }

    // Update reward variables of the given pool.
    public entry fun update_pool<CoinType>(
        clock_obj: &Clock,
        ryu_info: &mut RYUInfo,
        mc_data: &mut MasterChefData,
        ctx: &mut TxContext) {
        assert!(dynamic_object_field::exists_with_type<String, PoolInfo<CoinType>>(&mut mc_data.id, type_name::into_string(type_name::get<CoinType>())), TOKEN_NOT_EXIST);
        let pool = dynamic_object_field::borrow_mut<String, PoolInfo<CoinType>>(&mut mc_data.id, type_name::into_string(type_name::get<CoinType>()));

        let current_time = get_current_timestamp(clock_obj);
        if (current_time <= pool.last_reward_timestamp) return;
        let lp_supply = coin::value<CoinType>(&pool.coin_reserve);
        if (lp_supply <= 0) {
            pool.last_reward_timestamp = current_time;
            return
        };
        let multipler = get_multiplier(pool.last_reward_timestamp, current_time);
        let reward_RYU = multipler * mc_data.per_second_RYU * (pool.alloc_point as u128) / (mc_data.total_alloc_point as u128) ;

        let reward_coin = ryu::mint_coin(&mut mc_data.ryu_mint_cap, ryu_info, (reward_RYU as u64), ctx);
        coin::join(&mut pool.coin_reward, reward_coin);
        pool.acc_RYU_per_share = pool.acc_RYU_per_share + reward_RYU * ACC_RYU_PRECISION / (lp_supply as u128);
        pool.last_reward_timestamp = current_time;
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

    // // Withdraw without caring about rewards. EMERGENCY ONLY.
    // public entry fun emergency_withdraw<CoinType>(
    //     account: &signer
    // )  {
    //     let acc_addr = signer::address_of(account);
    //     assert!(exists<UserInfo<CoinType>>(acc_addr), INSUFFICIENT_AMOUNT);
    // }

    // Add a new LP to the pool. Can only be called by the owner.
    // DO NOT add the same LP coin more than once. Rewards will be messed up if you do.
    public entry fun add_pool<CoinType>(
        clock_obj: &Clock,
        master_chef: &mut MasterChefData,
        new_alloc_point: u64,
        ctx: &mut TxContext,
    ) {
        let addr = tx_context::sender(ctx);
        assert!(addr == master_chef.admin_address, ACCOUNT_FORBIDDEN);
        assert!(!dynamic_object_field::exists_with_type<String, PoolInfo<CoinType>>(&mut master_chef.id, type_name::into_string(type_name::get<CoinType>())), TOKEN_ALREADY_EXIST);
        // change mc data
        master_chef.total_alloc_point = master_chef.total_alloc_point + new_alloc_point;
        let last_reward_timestamp = (if (get_current_timestamp(clock_obj) > master_chef.start_timestamp) get_current_timestamp(clock_obj) else master_chef.start_timestamp);
        let pool_id = object::new(ctx);
        let pooladdr = object::uid_to_address(&pool_id);

        let pool = PoolInfo<CoinType> {
            id: pool_id,
            coin_reserve: coin::zero<CoinType>(ctx),
            coin_reward: coin::zero(ctx),
            acc_RYU_per_share: 0,
            last_reward_timestamp,
            alloc_point: new_alloc_point,
        };
        dynamic_object_field::add<String, PoolInfo<CoinType>>(&mut master_chef.id, type_name::into_string(type_name::get<CoinType>()), pool);

        vector::push_back(&mut master_chef.pool_list, pooladdr);

        // event
        event::emit(AddEvent {
            coin_name: type_name::into_string(type_name::get<CoinType>()),
            alloc_point: new_alloc_point,
        });
    }

    fun get_multiplier(
        from: u64,
        to: u64,
    ): u128 {
        ((to - from) as u128)
    }

    // Update the given pool's RYU allocation point
    public entry fun set_pool<CoinType>(
        mc_data: &mut MasterChefData,
        new_alloc_point: u64,
        ctx: &mut TxContext,
    ) {
        let addr = tx_context::sender(ctx);
        assert!(addr == mc_data.admin_address, ACCOUNT_FORBIDDEN);
        assert!(dynamic_object_field::exists_with_type<String, PoolInfo<CoinType>>(&mut mc_data.id, type_name::into_string(type_name::get<CoinType>())), TOKEN_NOT_EXIST);
        let pool = dynamic_object_field::borrow_mut<String, PoolInfo<CoinType>>(&mut mc_data.id, type_name::into_string(type_name::get<CoinType>()));

        mc_data.total_alloc_point = mc_data.total_alloc_point - pool.alloc_point + new_alloc_point;
        pool.alloc_point = new_alloc_point;
        //
        event::emit(SetEvent {
            coin_name: type_name::into_string(type_name::get<CoinType>()),
            alloc_point: new_alloc_point,
        });
    }

    fun get_current_timestamp(clock_obj: &Clock): u64 {
        return clock::timestamp_ms(clock_obj) / 1000
    }


    public entry fun set_admin_address(
        mc_data: &mut MasterChefData,
        new_addr: address,
        ctx: &mut TxContext,
    ) {
        let addr = tx_context::sender(ctx);
        assert!(addr == mc_data.admin_address, ACCOUNT_FORBIDDEN);
        mc_data.admin_address = new_addr;
    }


    public entry fun set_per_second_RYU(
        mc_data: &mut MasterChefData,
        per_second_RYU: u128,
        ctx: &mut TxContext,
    ) {
        let addr = tx_context::sender(ctx);
        assert!(addr == mc_data.admin_address, ACCOUNT_FORBIDDEN);
        assert!(per_second_RYU >= 1000000 && per_second_RYU <= 10000000000, ACCOUNT_FORBIDDEN);   // 0.01 - 100 RYU/s
        mc_data.per_second_RYU = per_second_RYU;
    }


    /**
     *  public functions for other contract
     */

    // vie function to see deposit amount
    public fun get_user_info_amount<CoinType>(
        user_info: &UserInfo<CoinType>,
    ): u64 {
        return user_info.amount
    }

    // View function to see pending RYUs
    public fun pending_RYU<CoinType>(
        user_info: &UserInfo<CoinType>,
        clock_obj: &Clock,
        ryu_info: &mut RYUInfo,
        mc_data: &mut MasterChefData,
        pool: &mut PoolInfo<CoinType>,
        ctx: &mut TxContext,
    ): u64 {
        update_pool<CoinType>(clock_obj, ryu_info, mc_data, ctx);
        let pending = (user_info.amount as u128) * pool.acc_RYU_per_share / ACC_RYU_PRECISION - user_info.reward_debt;
        (pending as u64)
    }

    public fun get_mc_data(mc_data: &MasterChefData): (u64, u64, u128) {
        (mc_data.total_alloc_point, mc_data.start_timestamp, mc_data.per_second_RYU)
    }

    public fun get_pool_info<CoinType>(pool_info: &PoolInfo<CoinType>): (u128, u64, u64) {
        (pool_info.acc_RYU_per_share, pool_info.last_reward_timestamp, pool_info.alloc_point)
    }

    public fun get_user_info<CoinType>(user_info: &UserInfo<CoinType>): (u64, u128) {
        (user_info.amount, user_info.reward_debt)
    }
}