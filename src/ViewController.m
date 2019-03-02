//
//  ViewController.m
//  machswap
//
//  Created by Ben on 23/01/2019.
//  Copyright © 2019 Ben. All rights reserved.
//

#import "ViewController.h"

#include <stdio.h>
#include <pthread.h>

#include "common.h"
#include "pwn.h"
#include "offsets.h"

@interface ViewController ()

@end

@implementation ViewController

- (id)initWithNav:(UINavigationController *)nav
{
    id ret = [super init];
    self.nav = nav;
    return ret;
}

void *haxxThread(void *arg)
{
    kern_return_t ret;

    offsets_t *offs = get_offsets();
    if (offs == NULL)
    {
        LOG("failed to get offsets!");
        return NULL;
    }
    
    mach_port_t tfp0;
    uint64_t kernel_base;
    ret = exploit(offs, &tfp0, &kernel_base);
    if (ret != KERN_SUCCESS)
    {
        LOG("failed to run exploit: %x %s", ret, mach_error_string(ret));
        return NULL;
    }

    LOG("success!");
    LOG("tfp0: %x", tfp0);
    LOG("kernel base: 0x%llx", kernel_base);

    return NULL;
}

- (void)viewDidLoad 
{
    [super viewDidLoad];

    pthread_t thd;
    pthread_create(&thd, NULL, &haxxThread, NULL);
}

@end
