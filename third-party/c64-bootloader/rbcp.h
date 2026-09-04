// array indices for efficient access of RBCP back-channel ROM area

// RBCP_HEADER
#define RBCP_GROUP           0
#define RBCP_CMD             1
#define RBCP_TOKEN           2
#define RBCP_PROGRESS        4
#define RBCP_RESPONSE        5

// RBCP_FLASH_SLOT_COUNT
#define RBCP_TOTAL_COUNT     8

// RBCP_FLASH_SLOT_INFO_ALL
#define RBCP_TOTAL_COUNT     8
#define RBCP_WHOLE_COUNT     9
#define RBCP_PARTIAL_FLAG    10
#define RBCP_ROM_TYPE_F      12  // 1st entry, add i * 32 for further entries
#define RBCP_NAME            13  // 1st entry, add i * 32 for further entries

// RBCP_RAM_SLOT_INFO
#define RBCP_TOTAL_COUNT     8
#define RBCP_ACTIVE_SLOT     9
#define RBCP_ROM_TYPE_R      10

// RBCP_DEVICE_TYPE
#define RBCP_DEVICE_TYPE     8

// RBCP_DEVICE_VERSION
#define RBCP_DEVICE_VERSION  8

// RBCP_PROTOCOL_VERSION
#define RBCP_MAJOR           8
#define RBCP_MINOR           9
#define RBCP_PATCH           10

typedef enum
{
    _2316 = 0x00,
    _2332,
    _2364,
    _23128,
    _23256,
    _2704,
    _2708,
    _2716,
    _2732,
    _2764,
    _27128,
    _27256,
    _27512,
    _231024,
    _27C010,
    _27C020,
    _27C040,
    _27C080,
    _27C400,
    _6116,
    _27C301,
    SST39SF040 = 0x19,
    _28C16,
    _28C64,
    _28C256,
    _28C512,
    INVALID = 0xFF	
} RBCP_ROM_TYPE;