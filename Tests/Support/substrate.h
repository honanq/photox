// Test-only declaration. CacheTests.m supplies a stub, never a real hook.
#pragma once
#import <objc/runtime.h>
void MSHookMessageEx(Class cls, SEL selector, IMP replacement, IMP *original);
