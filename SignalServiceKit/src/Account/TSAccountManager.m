//
// Copyright 2017 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

#import "TSAccountManager.h"
#import "AppContext.h"
#import "AppReadiness.h"
#import "HTTPUtils.h"
#import "OWSError.h"
#import "OWSRequestFactory.h"
#import "ProfileManagerProtocol.h"
#import "TSPreKeyManager.h"
#import <SignalCoreKit/NSData+OWS.h>
#import <SignalCoreKit/Randomness.h>
#import <SignalServiceKit/SignalServiceKit-Swift.h>

NS_ASSUME_NONNULL_BEGIN

NSNotificationName const NSNotificationNameRegistrationStateDidChange = @"NSNotificationNameRegistrationStateDidChange";
NSNotificationName const NSNotificationNameOnboardingStateDidChange = @"NSNotificationNameOnboardingStateDidChange";
NSString *const TSRemoteAttestationAuthErrorKey = @"TSRemoteAttestationAuth";
NSNotificationName const NSNotificationNameLocalNumberDidChange = @"NSNotificationNameLocalNumberDidChange";

NSString *const TSAccountManager_RegisteredNumberKey = @"TSStorageRegisteredNumberKey";
NSString *const TSAccountManager_RegistrationDateKey = @"TSAccountManager_RegistrationDateKey";
NSString *const TSAccountManager_RegisteredUUIDKey = @"TSStorageRegisteredUUIDKey";
NSString *const TSAccountManager_RegisteredPNIKey = @"TSAccountManager_RegisteredPNIKey";
NSString *const TSAccountManager_IsDeregisteredKey = @"TSAccountManager_IsDeregisteredKey";
NSString *const TSAccountManager_ReregisteringPhoneNumberKey = @"TSAccountManager_ReregisteringPhoneNumberKey";
NSString *const TSAccountManager_ReregisteringUUIDKey = @"TSAccountManager_ReregisteringUUIDKey";
NSString *const TSAccountManager_IsOnboardedKey = @"TSAccountManager_IsOnboardedKey";
NSString *const TSAccountManager_IsTransferInProgressKey = @"TSAccountManager_IsTransferInProgressKey";
NSString *const TSAccountManager_WasTransferredKey = @"TSAccountManager_WasTransferredKey";
NSString *const TSAccountManager_HasPendingRestoreDecisionKey = @"TSAccountManager_HasPendingRestoreDecisionKey";
NSString *const TSAccountManager_IsDiscoverableByPhoneNumberKey = @"TSAccountManager_IsDiscoverableByPhoneNumber";
NSString *const TSAccountManager_LastSetIsDiscoverableByPhoneNumberKey
    = @"TSAccountManager_LastSetIsDiscoverableByPhoneNumberKey";

NSString *const TSAccountManager_UserAccountCollection = @"TSStorageUserAccountCollection";
NSString *const TSAccountManager_ServerAuthTokenKey = @"TSStorageServerAuthToken";
NSString *const TSAccountManager_ManualMessageFetchKey = @"TSAccountManager_ManualMessageFetchKey";

NSString *const TSAccountManager_DeviceIdKey = @"TSAccountManager_DeviceId";

NSString *NSStringForOWSRegistrationState(OWSRegistrationState value)
{
    switch (value) {
        case OWSRegistrationState_Unregistered:
            return @"Unregistered";
        case OWSRegistrationState_PendingBackupRestore:
            return @"PendingBackupRestore";
        case OWSRegistrationState_Registered:
            return @"Registered";
        case OWSRegistrationState_Deregistered:
            return @"Deregistered";
        case OWSRegistrationState_Reregistering:
            return @"Reregistering";
    }
}

#pragma mark -

// We use @synchronized and db transactions often within this class.
// There's a risk of deadlock if we try to @synchronize within a transaction
// while another thread is trying to open a transaction while @synchronized.
// To avoid deadlocks, we follow these guidelines:
//
// * Don't use either unless necessary.
// * Only use one if possible.
// * If both must be used, only @synchronize within a transaction.
//   _Never_ open a transaction within a @synchronized(self) block.
// * If you update any account state in the database, reload the cache
//   immediately.
@interface TSAccountManager () <DatabaseChangeDelegate>

@end

#pragma mark -

@implementation TSAccountManager

@synthesize phoneNumberAwaitingVerification = _phoneNumberAwaitingVerification;
@synthesize uuidAwaitingVerification = _uuidAwaitingVerification;
@synthesize pniAwaitingVerification = _pniAwaitingVerification;

- (instancetype)init
{
    self = [super init];
    if (!self) {
        return self;
    }

    _keyValueStore = [[SDSKeyValueStore alloc] initWithCollection:TSAccountManager_UserAccountCollection];

    OWSSingletonAssert();

    AppReadinessRunNowOrWhenAppDidBecomeReadySync(^{
        if (!CurrentAppContext().isMainApp) {
            [self.databaseStorage appendDatabaseChangeDelegate:self];
        }
    });
    AppReadinessRunNowOrWhenAppDidBecomeReadyAsync(^{ [self updateAccountAttributesIfNecessary]; });

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reachabilityChanged)
                                                 name:SSKReachability.owsReachabilityDidChange
                                               object:nil];

    return self;
}

#pragma mark -

- (nullable NSString *)phoneNumberAwaitingVerification
{
    @synchronized(self) {
        return _phoneNumberAwaitingVerification;
    }
}

- (nullable NSUUID *)uuidAwaitingVerification
{
    @synchronized(self) {
        return _uuidAwaitingVerification;
    }
}

- (nullable NSUUID *)pniAwaitingVerification
{
    @synchronized(self) {
        return _pniAwaitingVerification;
    }
}

- (void)setPhoneNumberAwaitingVerification:(NSString *_Nullable)phoneNumberAwaitingVerification
{
    @synchronized(self) {
        _phoneNumberAwaitingVerification = phoneNumberAwaitingVerification;
    }

    [[NSNotificationCenter defaultCenter] postNotificationNameAsync:NSNotificationNameLocalNumberDidChange
                                                             object:nil
                                                           userInfo:nil];
}

- (void)setUuidAwaitingVerification:(NSUUID *_Nullable)uuidAwaitingVerification
{
    @synchronized(self) {
        _uuidAwaitingVerification = uuidAwaitingVerification;
    }
}

- (void)setPniAwaitingVerification:(NSUUID *_Nullable)pniAwaitingVerification
{
    @synchronized(self) {
        _pniAwaitingVerification = pniAwaitingVerification;
    }
}

- (void)updateLocalPhoneNumber:(E164ObjC *)e164
                           aci:(NSUUID *)uuid
                           pni:(NSUUID *_Nullable)pni
                   transaction:(SDSAnyWriteTransaction *)transaction
{
    [self storeLocalNumber:e164.stringValue
                       aci:[[ServiceIdObjC alloc] initWithUuidValue:uuid]
                       pni:(pni == nil ? nil : [[ServiceIdObjC alloc] initWithUuidValue:pni])
               transaction:transaction];

    [transaction addAsyncCompletionOffMain:^{
        [self postRegistrationStateDidChangeNotification];

        [[NSNotificationCenter defaultCenter] postNotificationNameAsync:NSNotificationNameLocalNumberDidChange
                                                                 object:nil
                                                               userInfo:nil];
    }];
}

- (TSAccountState *)loadAccountStateWithTransaction:(SDSAnyReadTransaction *)transaction
{
    OWSLogVerbose(@"");

    // This method should only be called while @synchronized on self.
    TSAccountState *accountState = [[TSAccountState alloc] initWithTransaction:transaction
                                                                 keyValueStore:self.keyValueStore];
    self.cachedAccountState = accountState;
    return accountState;
}

- (TSAccountState *)getOrLoadAccountStateWithSneakyTransaction
{
    @synchronized (self) {
        if (self.cachedAccountState != nil) {
            return self.cachedAccountState;
        }
    }

    return [self loadAccountStateWithSneakyTransaction];
}

- (TSAccountState *)loadAccountStateWithSneakyTransaction
{
    // We avoid opening a transaction while @synchronized.
    __block TSAccountState *accountState;
    [self.databaseStorage readWithBlock:^(SDSAnyReadTransaction *transaction) {
        @synchronized(self) {
            accountState = [self loadAccountStateWithTransaction:transaction];
        }
    } file:__FILE__ function:__FUNCTION__ line:__LINE__];

    OWSAssertDebug(accountState != nil);
    return accountState;
}

- (TSAccountState *)getOrLoadAccountStateWithTransaction:(SDSAnyReadTransaction *)transaction
{
    @synchronized(self) {
        if (self.cachedAccountState != nil) {
            return self.cachedAccountState;
        }

        [self loadAccountStateWithTransaction:transaction];

        OWSAssertDebug(self.cachedAccountState != nil);

        return self.cachedAccountState;
    }
}

- (void)didRegister
{
    OWSLogInfo(@"");
    NSString *phoneNumber;
    NSUUID *aci;
    NSUUID *pni;
    @synchronized(self) {
        phoneNumber = self.phoneNumberAwaitingVerification;
        aci = self.uuidAwaitingVerification;
        pni = self.pniAwaitingVerification;
    }

    if (!phoneNumber) {
        OWSFail(@"phoneNumber was unexpectedly nil");
    }

    if (!aci) {
        OWSFail(@"uuid was unexpectedly nil");
    }

    if (!pni) {
        OWSFail(@"pni was unexpectedly nil");
    }

    DatabaseStorageWrite(self.databaseStorage, ^(SDSAnyWriteTransaction *transaction) {
        [self storeLocalNumber:phoneNumber
                           aci:[[ServiceIdObjC alloc] initWithUuidValue:aci]
                           pni:[[ServiceIdObjC alloc] initWithUuidValue:pni]
                   transaction:transaction];
    });

    [self postRegistrationStateDidChangeNotification];
}

- (void)didRegisterPrimaryWithE164:(E164ObjC *)e164
                               aci:(NSUUID *)aci
                               pni:(NSUUID *)pni
                         authToken:(NSString *)authToken
                       transaction:(SDSAnyWriteTransaction *)transaction
{
    [self storeLocalNumber:e164.stringValue
                       aci:[[ServiceIdObjC alloc] initWithUuidValue:aci]
                       pni:[[ServiceIdObjC alloc] initWithUuidValue:pni]
               transaction:transaction];
    [self setStoredServerAuthToken:authToken deviceId:OWSDeviceObjc.primaryDeviceId transaction:transaction];
    [transaction addSyncCompletion:^{ [self postRegistrationStateDidChangeNotification]; }];
}

+ (nullable NSString *)localNumber
{
    return [[self shared] localNumber];
}

- (nullable NSString *)localNumber
{
    return [self localNumberWithAccountState:[self getOrLoadAccountStateWithSneakyTransaction]];
}

- (nullable NSString *)localNumberWithTransaction:(SDSAnyReadTransaction *)transaction
{
    return [self localNumberWithAccountState:[self getOrLoadAccountStateWithTransaction:transaction]];
}

- (nullable NSString *)localNumberWithAccountState:(TSAccountState *)accountState
{
    @synchronized(self)
    {
        NSString *awaitingVerif = self.phoneNumberAwaitingVerification;
        if (awaitingVerif) {
            return awaitingVerif;
        }
    }

    return accountState.localNumber;
}

- (nullable NSUUID *)localUuid
{
    return [self localUuidWithAccountState:[self getOrLoadAccountStateWithSneakyTransaction]];
}

- (nullable NSUUID *)localUuidWithTransaction:(SDSAnyReadTransaction *)transaction
{
    return [self localUuidWithAccountState:[self getOrLoadAccountStateWithTransaction:transaction]];
}

- (nullable NSUUID *)localUuidWithAccountState:(TSAccountState *)accountState
{
    @synchronized(self) {
        NSUUID *awaitingVerif = self.uuidAwaitingVerification;
        if (awaitingVerif) {
            return awaitingVerif;
        }
    }

    return accountState.localUuid;
}

- (nullable NSUUID *)localPni
{
    return [self localPniWithAccountState:[self getOrLoadAccountStateWithSneakyTransaction]];
}

- (nullable NSUUID *)localPniWithTransaction:(SDSAnyReadTransaction *)transaction
{
    return [self localPniWithAccountState:[self getOrLoadAccountStateWithTransaction:transaction]];
}

- (nullable NSUUID *)localPniWithAccountState:(TSAccountState *)accountState
{
    @synchronized(self) {
        NSUUID *awaitingVerif = self.pniAwaitingVerification;
        if (awaitingVerif) {
            return awaitingVerif;
        }
    }

    return accountState.localPni;
}

+ (nullable SignalServiceAddress *)localAddressWithTransaction:(SDSAnyReadTransaction *)transaction
{
    return [self.shared localAddressWithTransaction:transaction];
}

- (nullable SignalServiceAddress *)localAddressWithTransaction:(SDSAnyReadTransaction *)transaction
{
    TSAccountState *accountState = [self getOrLoadAccountStateWithTransaction:transaction];
    return [self localAddressWithAccountState:accountState];
}

+ (nullable SignalServiceAddress *)localAddress
{
    return [[self shared] localAddress];
}

- (nullable SignalServiceAddress *)localAddress
{
    TSAccountState *accountState = [self getOrLoadAccountStateWithSneakyTransaction];
    return [self localAddressWithAccountState:accountState];
}

- (nullable SignalServiceAddress *)localAddressWithAccountState:(TSAccountState *)accountState
{
    // We extract uuid and local number from a single instance of accountState to avoid races.
    NSUUID *_Nullable localUuid = [self localUuidWithAccountState:accountState];
    NSString *_Nullable localNumber = [self localNumberWithAccountState:accountState];
    if (localUuid == nil && localNumber == nil) {
        return nil;
    }
    return [[SignalServiceAddress alloc] initWithUuid:localUuid phoneNumber:localNumber];
}

- (void)setIsOnboarded:(BOOL)isOnboarded transaction:(SDSAnyWriteTransaction *)transaction
{
    @synchronized(self) {
        [self.keyValueStore setBool:isOnboarded key:TSAccountManager_IsOnboardedKey transaction:transaction];
        [self loadAccountStateWithTransaction:transaction];
    }
    [self postOnboardingStateDidChangeNotification];
}

- (void)setStoredServerAuthToken:(NSString *)authToken
                        deviceId:(UInt32)deviceId
                     transaction:(SDSAnyWriteTransaction *)transaction
{
    @synchronized(self) {
        [self.keyValueStore setString:authToken key:TSAccountManager_ServerAuthTokenKey transaction:transaction];
        [self.keyValueStore setUInt32:deviceId key:TSAccountManager_DeviceIdKey transaction:transaction];

        [self loadAccountStateWithTransaction:transaction];
    }
}

#pragma mark - Re-registration

- (BOOL)resetForReregistration
{
    TSAccountState *oldAccountState = [self getOrLoadAccountStateWithSneakyTransaction];
    NSString *_Nullable localNumber = oldAccountState.localNumber;
    if (!localNumber) {
        OWSFailDebug(@"can't re-register without local number.");
        return NO;
    }
    E164ObjC *_Nullable localE164 = [[E164ObjC alloc] init:localNumber];
    if (!localE164) {
        OWSFailDebug(@"can't re-register without valid local number.");
        return NO;
    }
    NSUUID *_Nullable localUUID = oldAccountState.localUuid;
    if (!localUUID) {
        OWSFailDebug(@"can't re-register without valid uuid.");
        return NO;
    }

    BOOL wasPrimaryDevice = oldAccountState.deviceId == OWSDeviceObjc.primaryDeviceId;


    DatabaseStorageWrite(self.databaseStorage, ^(SDSAnyWriteTransaction *transaction) {
        [self resetForReregistrationWithLocalPhoneNumber:localE164
                                                localAci:localUUID
                                        wasPrimaryDevice:wasPrimaryDevice
                                             transaction:transaction];
    });
    return YES;
}

- (void)resetForReregistrationWithLocalPhoneNumber:(E164ObjC *)localPhoneNumber
                                          localAci:(NSUUID *)localAci
                                  wasPrimaryDevice:(BOOL)wasPrimaryDevice
                                       transaction:(SDSAnyWriteTransaction *)transaction
{
    @synchronized(self) {
        self.phoneNumberAwaitingVerification = nil;
        self.uuidAwaitingVerification = nil;
        self.pniAwaitingVerification = nil;

        [self.keyValueStore removeAllWithTransaction:transaction];

        [[self signalProtocolStoreForIdentity:OWSIdentityACI].sessionStore resetSessionStore:transaction];
        [[self signalProtocolStoreForIdentity:OWSIdentityPNI].sessionStore resetSessionStore:transaction];
        [self.senderKeyStore resetSenderKeyStoreWithTransaction:transaction];

        [self.udManager removeSenderCertificatesWithTransaction:transaction];

        [self.versionedProfiles clearProfileKeyCredentialsWithTransaction:transaction];

        [self.groupsV2 clearTemporalCredentialsWithTransaction:transaction];

        [self.keyValueStore setObject:localPhoneNumber.stringValue
                                  key:TSAccountManager_ReregisteringPhoneNumberKey
                          transaction:transaction];
        [self.keyValueStore setObject:localAci.UUIDString
                                  key:TSAccountManager_ReregisteringUUIDKey
                          transaction:transaction];

        [self.keyValueStore setBool:NO key:TSAccountManager_IsOnboardedKey transaction:transaction];

        if (wasPrimaryDevice) {
            // Don't reset payments state at this time.
        } else {
            // PaymentsEvents will dispatch this event to the appropriate singletons.
            [self.paymentsEvents clearStateWithTransaction:transaction];
        }

        [self loadAccountStateWithTransaction:transaction];
    }

    [transaction addAsyncCompletionOnMain:^(void) {
        [self postRegistrationStateDidChangeNotification];
        [self postOnboardingStateDidChangeNotification];
    }];
}

- (BOOL)isManualMessageFetchEnabled
{
    __block BOOL result;
    [self.databaseStorage readWithBlock:^(
        SDSAnyReadTransaction *transaction) { result = [self isManualMessageFetchEnabled:transaction]; }];
    return result;
}

- (BOOL)isManualMessageFetchEnabled:(SDSAnyReadTransaction *)transaction
{
    return [self.keyValueStore getBool:TSAccountManager_ManualMessageFetchKey defaultValue:NO transaction:transaction];
}

- (void)setIsManualMessageFetchEnabled:(BOOL)value
{
    DatabaseStorageWrite(self.databaseStorage, ^(SDSAnyWriteTransaction *transaction) {
        [self setIsManualMessageFetchEnabled:value transaction:transaction];
    });
}

- (void)setIsManualMessageFetchEnabled:(BOOL)value transaction:(SDSAnyWriteTransaction *)transaction
{
    [self.keyValueStore setBool:value key:TSAccountManager_ManualMessageFetchKey transaction:transaction];
}

- (void)registerForTestsWithLocalNumber:(NSString *)localNumber uuid:(NSUUID *)uuid
{
    [self registerForTestsWithLocalNumber:localNumber uuid:uuid pni:nil];
}

- (void)registerForTestsWithLocalNumber:(NSString *)localNumber uuid:(NSUUID *)uuid pni:(NSUUID *_Nullable)pni
{
    OWSAssertDebug(SSKFeatureFlags.storageMode == StorageModeGrdbTests);
    OWSAssertDebug(CurrentAppContext().isRunningTests);
    OWSAssertDebug(localNumber.length > 0);
    OWSAssertDebug(uuid != nil);

    DatabaseStorageWrite(self.databaseStorage, ^(SDSAnyWriteTransaction *transaction) {
        [self storeLocalNumber:localNumber
                           aci:[[ServiceIdObjC alloc] initWithUuidValue:uuid]
                           pni:(pni == nil ? nil : [[ServiceIdObjC alloc] initWithUuidValue:pni])
                   transaction:transaction];
    });
}

- (void)reachabilityChanged {
    OWSAssertIsOnMainThread();

    AppReadinessRunNowOrWhenAppDidBecomeReadyAsync(^{ [self updateAccountAttributesIfNecessary]; });
}

#pragma mark - DatabaseChangeDelegate

- (void)databaseChangesDidUpdateWithDatabaseChanges:(id<DatabaseChanges>)databaseChanges
{
    OWSAssertIsOnMainThread();
    OWSAssertDebug(AppReadiness.isAppReady);

    // Do nothing.
}

- (void)databaseChangesDidUpdateExternally
{
    OWSAssertIsOnMainThread();
    OWSAssertDebug(AppReadiness.isAppReady);

    OWSLogVerbose(@"");

    // Any database write by the main app might reflect a deregistration,
    // so clear the cached "is registered" state.  This will significantly
    // erode the value of this cache in the SAE.
    [self loadAccountStateWithSneakyTransaction];
}

- (void)databaseChangesDidReset
{
    OWSAssertIsOnMainThread();
    OWSAssertDebug(AppReadiness.isAppReady);

    // Do nothing.
}

@end

NS_ASSUME_NONNULL_END
