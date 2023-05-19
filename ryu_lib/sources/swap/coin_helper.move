module ryulib::coin_helper {
    use std::type_name;
    use std::ascii;
    use ryulib::comparator;
    use ryulib::comparator::Result;


    // Errors codes.

    /// When both coins have same names and can't be ordered.
    const ERR_CANNOT_BE_THE_SAME_COIN: u64 = 3000;

    /// When provided CoinType is not a coin.
    const ERR_IS_NOT_COIN: u64 = 3001;

    // Constants.
    /// Length of symbol prefix to be used in LP coin symbol.
    const SYMBOL_PREFIX_LENGTH: u64 = 4;


    /// Compare two coins, `X` and `Y`, using names.
    /// Caller should call this function to determine the order of X, Y.
    public fun compare<X, Y>(): Result {
        let x_tn = type_name::get<X>();
        let x_str = type_name::into_string(x_tn);
        let x_bytes = ascii::into_bytes(x_str);

        let y_tn = type_name::get<Y>();
        let y_str = type_name::into_string(y_tn);
        let y_bytes = ascii::into_bytes(y_str);

        let result = comparator::compare_u8_vector(x_bytes, y_bytes);
        result
    }

    /// Check that coins generics `X`, `Y` are sorted in correct ordering.
    /// X != Y && X.symbol < Y.symbol
    public fun is_sorted<X, Y>(): bool {
        let order = compare<X, Y>();
        assert!(!comparator::is_equal(&order), ERR_CANNOT_BE_THE_SAME_COIN);
        comparator::is_smaller_than(&order)
    }
}
