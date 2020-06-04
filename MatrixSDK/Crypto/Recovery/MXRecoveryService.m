/*
 Copyright 2020 The Matrix.org Foundation C.I.C
 
 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at
 
 http://www.apache.org/licenses/LICENSE-2.0
 
 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

#import "MXRecoveryService_Private.h"


#import "MXCrypto_Private.h"
#import "MXKeyBackupPassword.h"
#import "MXRecoveryKey.h"
#import "MXTools.h"
#import "NSArray+MatrixSDK.h"


@interface MXRecoveryService ()
{
}

@property (nonatomic, readonly, weak) MXCrypto *crypto;
@property (nonatomic, readonly, weak) id<MXCryptoStore> cryptoStore;
@property (nonatomic, readonly, weak) MXSecretStorage *secretStorage;

@end


@implementation MXRecoveryService

#pragma mark - SDK-Private methods -

- (instancetype)initWithCrypto:(MXCrypto *)crypto;
{
    NSParameterAssert(crypto.store && crypto.secretStorage);
    
    self = [super init];
    if (self)
    {
        _crypto = crypto;
        _cryptoStore = crypto.store;
        _secretStorage = crypto.secretStorage;
        
        _supportedSecrets = @[
                              MXSecretId.crossSigningMaster,
                              MXSecretId.crossSigningSelfSigning,
                              MXSecretId.crossSigningUserSigning,
                              MXSecretId.keyBackup,
                              ];
    }
    return self;
}


#pragma mark - Public methods -

- (nullable NSString*)recoveryId
{
    return _secretStorage.defaultKeyId;
}

- (BOOL)hasRecovery
{
    return (self.recoveryId != nil);
}

- (BOOL)usePassphrase
{
    MXSecretStorageKeyContent *keyContent = [_secretStorage keyWithKeyId:self.recoveryId];
    {
        // No recovery at all
        return NO;
    }
    
    return (keyContent.passphrase != nil);
}


- (BOOL)hasSecretWithSecretId:(NSString*)secretId
{
     return ([_secretStorage keyWithKeyId:secretId] != nil);
}

- (NSArray<NSString*>*)storedSecrets
{
    NSMutableArray *storedSecrets = [NSMutableArray array];
    for (NSString *secretId in _supportedSecrets)
    {
        if ([self hasSecretWithSecretId:secretId])
        {
            [storedSecrets addObject:secretId];
        }
    }
    
    return storedSecrets;
}


- (BOOL)hasSecretLocally:(NSString*)secretId
{
    return ([_cryptoStore secretWithSecretId:secretId] != nil);
}

- (NSArray*)locallyStoredSecrets
{
    NSMutableArray *locallyStoredSecrets = [NSMutableArray array];
    for (NSString *secretId in _supportedSecrets)
    {
        if ([self hasSecretLocally:secretId])
        {
            [locallyStoredSecrets addObject:secretId];
        }
    }

    return locallyStoredSecrets;
}


- (void)createRecoveryWithPassphrase:(nullable NSString*)passphrase
                             success:(void (^)(MXSecretStorageKeyCreationInfo *keyCreationInfo))success
                             failure:(void (^)(NSError *error))failure
{
    if (!self.hasRecovery)
    {
        NSLog(@"[MXRecoveryService] createRecovery: Error: A recovery already exists.");
        failure(nil);
        return;
    }
    
    NSArray *locallyStoredSecrets = self.locallyStoredSecrets;
    NSLog(@"[MXRecoveryService] createRecovery: Secrets: %@", locallyStoredSecrets);
    
    MXWeakify(self);
    [_secretStorage createKeyWithKeyId:nil keyName:nil passphrase:passphrase success:^(MXSecretStorageKeyCreationInfo * _Nonnull keyCreationInfo) {
        MXStrongifyAndReturnIfNil(self);
        
        // Build the key
        NSDictionary<NSString*, NSData*> *keys = @{
                                                   keyCreationInfo.keyId: keyCreationInfo.privateKey
                                                   };
        
        dispatch_group_t dispatchGroup = dispatch_group_create();
        __block NSError *error;
        
        for (NSString *secretId in locallyStoredSecrets)
        {
            NSString *secret = [self.cryptoStore secretWithSecretId:secretId];
            
            if (secret)
            {
                dispatch_group_enter(dispatchGroup);
                [self.secretStorage storeSecret:secret withSecretId:secretId withSecretStorageKeys:keys success:^(NSString * _Nonnull secretId) {
                    dispatch_group_leave(dispatchGroup);
                } failure:^(NSError * _Nonnull anError) {
                    NSLog(@"[MXRecoveryService] createRecovery: Failed to store %@. Error: %@", secretId, anError);
                    
                    error = anError;
                    dispatch_group_leave(dispatchGroup);
                }];
            }
        }
        
        dispatch_group_notify(dispatchGroup, dispatch_get_main_queue(), ^{
            
            NSLog(@"[MXRecoveryService] createRecovery: Completed");
            
            if (error)
            {
                failure(error);
            }
            else
            {
                success(keyCreationInfo);
            }
        });
        
    } failure:^(NSError * _Nonnull error) {
        NSLog(@"[MXRecoveryService] createRecovery: Failed to create SSSS. Error: %@", error);
        failure(error);
    }];
}


- (void)recoverSecrets:(nullable NSArray<NSString*>*)secrets
        withPassphrase:(NSString*)passphrase
               success:(void (^)(NSArray<NSString*> *validSecrets, NSArray<NSString*> *invalidSecrets))success
               failure:(void (^)(NSError *error))failure
{
    NSLog(@"[MXRecoveryService] recoverSecrets(withPassphrase): %@", secrets);
    
    [self recoveryKeyFromPassphrase:passphrase success:^(NSData *privateKey) {
        
        [self recoverSecrets:secrets withPrivateKey:privateKey success:success failure:failure];
        
    } failure:failure];
}

- (void)recoverSecrets:(nullable NSArray<NSString*>*)secrets
        withPrivateKey:(NSData*)privateKey
               success:(void (^)(NSArray<NSString*> *validSecrets, NSArray<NSString*> *invalidSecrets))success
               failure:(void (^)(NSError *error))failure
{
    if (!secrets)
    {
        // Use default ones
        secrets = _supportedSecrets;
    }
    
    NSLog(@"[MXRecoveryService] recoverSecrets: %@", secrets);
    
    NSMutableArray<NSString*> *validSecrets = [NSMutableArray array];
    NSMutableArray<NSString*> *invalidSecrets = [NSMutableArray array];

    NSArray<NSString*> *storedSecrets = self.storedSecrets;
    NSArray<NSString*> *secretsToRecover = [storedSecrets mx_intersectArray:secrets];
    if (!secretsToRecover.count)
    {
        NSLog(@"[MXRecoveryService] recoverSecrets: No secrets to recover. storedSecrets: %@", storedSecrets);
        
        // No recovery at all
        success(validSecrets, invalidSecrets);
        return;
    }
    
    NSString *secretStorageKeyId = self.recoveryId;
    
    dispatch_group_t dispatchGroup = dispatch_group_create();
    __block NSError *error;
    
    for (NSString *secretId in secretsToRecover)
    {
        dispatch_group_enter(dispatchGroup);
        
        [_secretStorage secretWithSecretId:secretId withSecretStorageKeyId:secretStorageKeyId privateKey:privateKey success:^(NSString * _Nonnull unpaddedBase64Secret) {
            
            NSString *secret = unpaddedBase64Secret;
            
            // Validate the secret before storing it
            if ([self checkSecret:secret withSecretId:secretId])
            {
                NSLog(@"[MXRecoveryService] recoverSecrets: Recovered secret %@", secretId);
                
                [validSecrets addObject:secretId];
                [self.cryptoStore storeSecret:secret withSecretId:secretId];
            }
            else
            {
                NSLog(@"[MXRecoveryService] recoverSecrets: Secret %@ is invalid", secretId);
                [invalidSecrets addObject:secretId];
            }
            
            dispatch_group_leave(dispatchGroup);
            
        } failure:^(NSError * _Nonnull anError) {
            NSLog(@"[MXRecoveryService] recoverSecrets: Failed to restore %@. Error: %@", secretId, anError);
            
            error = anError;
            dispatch_group_leave(dispatchGroup);
        }];
    }
    
    dispatch_group_notify(dispatchGroup, dispatch_get_main_queue(), ^{
        
        if (error)
        {
            NSLog(@"[MXRecoveryService] recoverSecrets: Completed with error.");
            failure(error);
        }
        else
        {
            NSLog(@"[MXRecoveryService] recoverSecrets: Completed. validSecrets: %@. invalidSecrets: %@", validSecrets, invalidSecrets);
            success(validSecrets, invalidSecrets);
        }
    });
}


#pragma mark - Private methods -

- (void)recoveryKeyFromPassphrase:(NSString*)passphrase
                          success:(void (^)(NSData *privateKey))success
                          failure:(void (^)(NSError *error))failure
{
    MXSecretStorageKeyContent *keyContent = [_secretStorage keyWithKeyId:self.recoveryId];
    if (!keyContent.passphrase)
    {
        // No recovery at all or no passphrase
        failure(nil);
        return;
    }
    
    
    // Go to a queue for derivating the passphrase into a recovery key
    dispatch_async(_crypto.cryptoQueue, ^{
        
        NSError *error;
        NSData *privateKey = [MXKeyBackupPassword retrievePrivateKeyWithPassword:passphrase
                                                                                 salt:keyContent.passphrase.salt
                                                                           iterations:keyContent.passphrase.iterations
                                                                                error:&error];
        
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (privateKey)
            {
                success(privateKey);
            }
            else
            {
                failure(error);
            }
        });
    });
}

- (BOOL)checkSecret:(NSString*)secret withSecretId:(NSString*)secretId
{
    // TODO
//    if ([secretId isEqualToString:MXSecretId.keyBackup])
//    {
//
//    }

    // YES by default
    return YES;
}

@end
