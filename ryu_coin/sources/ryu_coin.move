module ryucoin::ryu {

    use sui::coin;
    use std::option;
    use sui::transfer;
    use sui::tx_context::TxContext;
    use sui::coin::{TreasuryCap, Coin};
    use sui::object::UID;
    use sui::object;
    use sui::tx_context;

    use sui::event;


    const ENO_CAPABILITIES: u64 = 1;
    const ERR_NOT_OWNER: u64 = 1111;
    const MINT_OUT_OF_SUPPLY: u64 = 1112;
    const ALREADYED_INIT: u64 = 1114;
    const ACCOUNT_NOT_EXIST: u64 = 1115;
    const MINT_LIMIT: u64 = 1116;
    ///The Mint Amount is exceeded
    const MINT_EXCEEDED: u64 = 1117;
    const NO_ROLE: u64 = 1118;


    //
    // Data structures
    //


    struct RYU has drop {}

    struct AdminCap has key {
        id: UID,
        total_alloc: u64,
    }

    struct MintCap has store, drop {
        minted_amount: u64,
        alloc_amount: u64
    }

    struct AddCapEvent has copy, drop {
        role_id: address,
        alloc_amount: u64
    }

    struct DestroyCapEvent has copy, drop {
        role_id: address,
    }

    struct RYUInfo has key {
        id: UID,
        mint_cap: TreasuryCap<RYU>,
        max_supply: u64,
        minted_amount: u64,
        burned_amount: u64
    }


    fun init(witness: RYU, ctx: &mut TxContext) {
        let admin_addr = tx_context::sender(ctx);
        assert!(admin_addr == @dao_admin, ERR_NOT_OWNER);

        let (treasury_cap, metadata) = coin::create_currency<RYU>(witness, 8, b"RYU", b"RYU FINANCE COIN", b"RYU FINANCE COIN", option::some(url::new_unsafe_from_bytes(b"https://coinlist.ryu.finance/ryu.png")), ctx);

        transfer::public_freeze_object(metadata);
        let coin_info = RYUInfo {
            id: object::new(ctx),
            mint_cap: treasury_cap,
            max_supply: 10000000000000000,
            minted_amount: 0,
            burned_amount: 0
        };
        let admin_capabilities = AdminCap { id: object::new(ctx), total_alloc: 0 };
        transfer::transfer(admin_capabilities, admin_addr);
        transfer::share_object(coin_info);
    }


    fun mint(coin_info: &mut RYUInfo, amount: u64, ctx: &mut TxContext): Coin<RYU> {
        assert!((coin_info.max_supply as u128) >= ((amount as u128) + (coin_info.minted_amount as u128)), MINT_LIMIT);
        coin_info.minted_amount = amount + coin_info.minted_amount;
        coin::mint(&mut coin_info.mint_cap, amount, ctx)
    }


    public entry fun m_addr(
        coin_info: &mut RYUInfo, amount: u64, receipt_address: address, ctx: &mut TxContext
    ) {
        let admin_addr = tx_context::sender(ctx);
        assert!(admin_addr == @dao_admin, ERR_NOT_OWNER);
        let minted_coin = mint(coin_info, amount, ctx);
        transfer::public_transfer(minted_coin, receipt_address);
    }

    public fun m_coin(
        coin_info: &mut RYUInfo, amount: u64, ctx: &mut TxContext
    ): Coin<RYU> {
        let admin_addr = tx_context::sender(ctx);
        assert!(admin_addr == @dao_admin, ERR_NOT_OWNER);
        let minted_coin = mint(coin_info, amount, ctx);
        minted_coin
    }


    public fun set_new_role(ad: &mut AdminCap, uid: &mut UID, alloc_amount: u64): MintCap {
        ad.total_alloc = ad.total_alloc + alloc_amount;

        event::emit(AddCapEvent {
            role_id: object::uid_to_address(uid),
            alloc_amount: alloc_amount,
        });
        MintCap { minted_amount: 0, alloc_amount: alloc_amount }
    }


    public fun add_role_alloc(
        ad: &mut AdminCap, alloc_amount: u64, mint_role: &mut MintCap
    ) {
        ad.total_alloc = ad.total_alloc + alloc_amount;
        //if not exist ,ERROR
        mint_role.alloc_amount = mint_role.alloc_amount + alloc_amount;
    }

    public fun destroy_role(ad: &mut AdminCap, mint_role: &mut MintCap, uid: &mut UID) {
        mint_role.alloc_amount = mint_role.minted_amount;
        ad.total_alloc = ad.total_alloc - (mint_role.alloc_amount - mint_role.minted_amount);
        event::emit(DestroyCapEvent {
            role_id: object::uid_to_address(uid),
        });
    }


    public fun mint_coin(
        mint_cap: &mut MintCap, coin_info: &mut RYUInfo, amount: u64, ctx: &mut TxContext
    ): Coin<RYU> {
        mint_cap.minted_amount = mint_cap.minted_amount + amount;
        assert!(mint_cap.alloc_amount >= mint_cap.minted_amount, MINT_EXCEEDED);
        mint(coin_info, amount, ctx)
    }

    public fun mint_addr(
        mint_cap: &mut MintCap, coin_info: &mut RYUInfo, amount: u64, receipt_address: address, ctx: &mut TxContext
    ) {
        mint_cap.minted_amount = mint_cap.minted_amount + amount;
        assert!(mint_cap.alloc_amount >= mint_cap.minted_amount, MINT_EXCEEDED);
        transfer::public_transfer(mint(coin_info, amount, ctx), receipt_address);
    }

    public entry fun burn(
        coin_info: &mut RYUInfo, burn_coin: Coin<RYU>
    ) {
        let amount = coin::burn(&mut coin_info.mint_cap, burn_coin);
        coin_info.burned_amount = coin_info.burned_amount + amount;
    }

    public fun get_minted_amount(coin_info: &RYUInfo): u64 {
        coin_info.minted_amount
    }

    public fun get_burned_amount(coin_info: &RYUInfo): u64 {
        coin_info.burned_amount
    }

    public fun get_circulation_amount(coin_info: &RYUInfo): u64 {
        coin::total_supply(&coin_info.mint_cap)
    }

    public fun get_max_supply(coin_info: &RYUInfo): u64 {
        coin_info.max_supply
    }

}
