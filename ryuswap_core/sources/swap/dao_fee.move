module ryufinance::dao_fee {

    use sui::balance::Balance;
    use sui::balance;
    use sui::object::UID;
    use std::ascii::String;
    use sui::tx_context;
    use sui::tx_context::TxContext;
    use sui::transfer;
    use sui::object;
    use sui::coin;
    use sui::dynamic_field;
    use std::type_name;
    use sui::event;
    use sui::coin::Coin;
    friend ryufinance::swap;


    /// When storage doesn't exists
    const ERR_NOT_REGISTERED: u64 = 401;
    /// When storage doesn't exists
    const ERR_REGISTERED: u64 = 402;

    /// When invalid DAO admin account
    const ERR_NOT_ADMIN_ACCOUNT: u64 = 402;

    // Public functions.

    struct DaoFeeInfo has key {
        id: UID,
    }

    /// Storage for keeping coins
    struct DaoFee<phantom X, phantom Y> has store {
        coin_x: Balance<X>,
        coin_y: Balance<Y>
    }


    /// Register storage
    /// Parameters:
    /// * `owner` - owner of storage
    public(friend) fun initialize(ctx: &mut TxContext) {
        transfer::share_object(DaoFeeInfo {
            id: object::new(ctx)
        })
    }


    /// Deposit coins to storage from liquidity pool
    /// Parameters:
    /// * `pool_addr` - pool owner address
    /// * `coin_x` - X coin to deposit
    /// * `coin_y` - Y coin to deposit
    public(friend) fun deposit<X, Y>(dao_storage_info: &mut DaoFeeInfo, bal_x: Balance<X>, bal_y: Balance<Y>) {
        assert!(dynamic_field::exists_(&mut dao_storage_info.id, type_name::into_string(type_name::get<DaoFee<X, Y>>())), ERR_NOT_REGISTERED);

        let storage = dynamic_field::borrow_mut<String, DaoFee<X, Y>>(&mut dao_storage_info.id, type_name::into_string(type_name::get<DaoFee<X, Y>>()));

        let x_val = balance::value(&bal_x);
        let y_val = balance::value(&bal_y);

        balance::join(&mut storage.coin_x, bal_x);
        balance::join(&mut storage.coin_y, bal_y);

        event::emit(
            CoinDepositedEvent<X, Y> { x_val, y_val }
        );
    }

    /// Register storage
    /// Parameters:
    /// * `owner` - owner of storage
    public(friend) fun register<X, Y>(dao_storage: &mut DaoFeeInfo) {
        let storage = DaoFee<X, Y> { coin_x: balance::zero<X>(), coin_y: balance::zero<Y>() };
        assert!(!dynamic_field::exists_(&mut dao_storage.id, type_name::into_string(type_name::get<DaoFee<X, Y>>())), ERR_REGISTERED);
        dynamic_field::add(&mut dao_storage.id, type_name::into_string(type_name::get<DaoFee<X, Y>>()), storage);
        event::emit(FeeCreatedEvent<X, Y> {});
    }

    public(friend) fun getBalance<X, Y>(dao_storage_info: &mut DaoFeeInfo): (u64, u64) {
        assert!(dynamic_field::exists_(&mut dao_storage_info.id, type_name::into_string(type_name::get<DaoFee<X, Y>>())), ERR_NOT_REGISTERED);
        let storage = dynamic_field::borrow_mut<String, DaoFee<X, Y>>(&mut dao_storage_info.id, type_name::into_string(type_name::get<DaoFee<X, Y>>()));
        (balance::value(&storage.coin_x), balance::value(&storage.coin_y))
    }

    /// Withdraw coins from storage
    /// Parameters:
    /// * `dao_admin_acc` - DAO admin
    /// * `pool_addr` - pool owner address
    /// * `x_val` - amount of X coins to withdraw
    /// * `y_val` - amount of Y coins to withdraw
    /// Returns both withdrawn X and Y coins: `(Coin<X>, Coin<Y>)`.
    public fun withdraw<X, Y>(dao_storage_info: &mut DaoFeeInfo, x_val: u64, y_val: u64, ctx: &mut TxContext): (Coin<X>, Coin<Y>) {
        assert!(tx_context::sender(ctx) == @dao_admin, ERR_NOT_ADMIN_ACCOUNT);
        assert!(dynamic_field::exists_(&mut dao_storage_info.id, type_name::into_string(type_name::get<DaoFee<X, Y>>())), ERR_NOT_REGISTERED);
        let storage = dynamic_field::borrow_mut<String, DaoFee<X, Y>>(&mut dao_storage_info.id, type_name::into_string(type_name::get<DaoFee<X, Y>>()));

        let bal_x = balance::split(&mut storage.coin_x, x_val);
        let bal_y = balance::split(&mut storage.coin_y, y_val);

        event::emit(CoinWithdrawnEvent<X, Y> { x_val, y_val });
        (coin::from_balance(bal_x, ctx), coin::from_balance(bal_y, ctx))
    }


    struct FeeCreatedEvent<phantom X, phantom Y> has copy, drop {}

    struct CoinDepositedEvent<phantom X, phantom Y> has copy, drop {
        x_val: u64,
        y_val: u64,
    }

    struct CoinWithdrawnEvent<phantom X, phantom Y> has copy, drop {
        x_val: u64,
        y_val: u64,
    }
}
