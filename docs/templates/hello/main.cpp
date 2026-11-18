#include <iostream>

extern "C" const char *quectel_pi_message(void);

int main()
{
    std::cout << quectel_pi_message() << std::endl;
    return 0;
}
