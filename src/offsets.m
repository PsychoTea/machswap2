#include <errno.h>
#include <string.h>             // strcmp, strerror
#include <sys/utsname.h>        // uname

#include "common.h"             // LOG, kptr_t
#include "offsets.h"

static offsets_t *offsets[] =
{
    &(offsets_t)
    {
        .constant =
        {
            .version = "Darwin Kernel Version 18.2.0: Mon Nov 12 20:32:02 PST 2018; root:xnu-4903.232.2~1/RELEASE_ARM64_S8000",
            .kernel_image_base = 0xfffffff007004000,
        },
        .struct_offsets =
        {
            .proc_pid = 0x60,
            .proc_task = 0x10,
            .proc_ucred = 0xf8,
            .task_vm_map = 0x20,
            .task_bsd_info = 0x358,
            .task_itk_self = 0xd8,
            .task_itk_registered = 0x2e8,
            .task_all_image_info_addr = 0x398,
            .task_all_image_info_size = 0x3a0,
        },
        .iosurface = 
        {
            .create_outsize = 0xdd0,
            .get_external_trap_for_index = 0xb7,
        },
    },
    &(offsets_t)
    {
        .constant =
        {
            .version = "Darwin Kernel Version 18.2.0: Mon Nov 12 20:32:02 PST 2018; root:xnu-4903.232.2~1/RELEASE_ARM64_T8010",
            .kernel_image_base = 0xfffffff007004000,
        },
        .struct_offsets =
        {
            .proc_pid = 0x60,
            .proc_task = 0x10,
            .proc_ucred = 0xf8,
            .task_vm_map = 0x20,
            .task_bsd_info = 0x358,
            .task_itk_self = 0xd8,
            .task_itk_registered = 0x2e8,
            .task_all_image_info_addr = 0x398,
            .task_all_image_info_size = 0x3a0,
        },
        .iosurface = 
        {
            .create_outsize = 0xdd0,
            .get_external_trap_for_index = 0xb7,
        },
    },
    &(offsets_t)
    {
        .constant =
        {
            .version = "Darwin Kernel Version 17.7.0: Mon Jun 11 19:06:26 PDT 2018; root:xnu-4570.70.24~3/RELEASE_ARM64_S5L8960X",
            .kernel_image_base = 0xfffffff007004000,
        },
        .struct_offsets =
        {
            .proc_pid = 0x10,
            .proc_task = 0x18,
            .proc_ucred = 0x100,
            .task_vm_map = 0x20,
            .task_bsd_info = 0x368,
            .task_itk_self = 0xd8,
            .task_itk_registered = 0x2f0,
            .task_all_image_info_addr = 0x3a8,
            .task_all_image_info_size = 0x3b0,
        },
        .iosurface = 
        {
            .create_outsize = 0xbc8,
            .get_external_trap_for_index = 0xb7,
        },
    },
    &(offsets_t)
    {
        .constant =
        {
            .version = "Darwin Kernel Version 16.7.0: Thu Jun 15 18:33:35 PDT 2017; root:xnu-3789.70.16~4/RELEASE_ARM64_S5L8960X",
            .kernel_image_base = 0xfffffff007004000,
        },
        .struct_offsets =
        {
            .proc_pid = 0x10,
            .proc_task = 0x18,
            .proc_ucred = 0x100,
            .task_vm_map = 0x20,
            .task_bsd_info = 0x360,
            .task_itk_self = 0xd8,
            .task_itk_registered = 0x2e8,
            .task_all_image_info_addr = 0x3a0,
            .task_all_image_info_size = 0x3a8,
        },
        .iosurface = 
        {
            .create_outsize = 0x3c8,
            .get_external_trap_for_index = 0xb7,
        },
    },
    NULL,
};

offsets_t *get_offsets(void)
{
    struct utsname u;
    if (uname(&u) != 0)
    {
        LOG("uname: %s", strerror(errno));
        return 0;
    }

    for (size_t i = 0; offsets[i] != 0; ++i)
    {
        if (strcmp(u.version, offsets[i]->constant.version) == 0)
        {
            return offsets[i];
        }
    }

    LOG("Failed to get offsets for kernel version: %s", u.version);
    return NULL;
}
