// PARAM: --enable ana.int.interval_set --set ana.context.gas_value 10
// Basic examples

int f(int x, int y)
{
    if (x == 0)
    {
        return y;
    }
    return f(x - 1, y - 1);
}

int main()
{
    __goblint_check(f(8, 8) == 0); // boundary (included)
}