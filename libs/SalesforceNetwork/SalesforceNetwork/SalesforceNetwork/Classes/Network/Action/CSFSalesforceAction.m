/*
 Copyright (c) 2015, salesforce.com, inc. All rights reserved.
 
 Redistribution and use of this software in source and binary forms, with or without modification,
 are permitted provided that the following conditions are met:
 * Redistributions of source code must retain the above copyright notice, this list of conditions
 and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright notice, this list of
 conditions and the following disclaimer in the documentation and/or other materials provided
 with the distribution.
 * Neither the name of salesforce.com, inc. nor the names of its contributors may be used to
 endorse or promote products derived from this software without specific prior written
 permission of salesforce.com, inc.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR
 IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND
 FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
 WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY
 WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "CSFSalesforceAction_Internal.h"
#import "CSFNetwork+Internal.h"
#import "CSFInternalDefines.h"
#import "CSFSalesforceOAuthRefresh.h"
#import <SalesforceSDKCore/SalesforceSDKCore.h>

NSString * const CSFAuthorizationHeaderValueFormat = @"OAuth %@";
NSString * const CSFAuthorizationHeaderName = @"Authorization";
NSString * const CSFSalesforceActionDefaultPathPrefix = @"/services/data";
NSString * const CSFSalesforceDefaultAPIVersion = @"v32.0";

static void * kObservingKey = &kObservingKey;

@implementation CSFSalesforceAction

- (instancetype)initWithResponseBlock:(CSFActionResponseBlock)responseBlock {
    self = [super initWithResponseBlock:responseBlock];
    if (self) {
        _returnsSecurityToken = YES; // YES by default
        _apiVersion = CSFSalesforceDefaultAPIVersion;
        _pathPrefix = CSFSalesforceActionDefaultPathPrefix;
        self.authRefreshClass = [CSFSalesforceOAuthRefresh class];
    }
    return self;
}

- (NSDictionary *)headersForAction {
    NSMutableDictionary *httpHeaders = (NSMutableDictionary*)[super headersForAction];
    if (![httpHeaders isKindOfClass:[NSMutableDictionary class]]) {
        httpHeaders = [httpHeaders mutableCopy];
    }
    
    httpHeaders[@"X-Chatter-Entity-Encoding"] = @"false";
    
    CSFNetwork *network = self.enqueuedNetwork;
    if (self.requiresAuthentication) {
        NSString *accessToken = network.account.credentials.accessToken;
        if (accessToken) {
            httpHeaders[CSFAuthorizationHeaderName] = [NSString stringWithFormat:CSFAuthorizationHeaderValueFormat, accessToken];
        }
    }
    
    return httpHeaders;
}

- (void)setEnqueuedNetwork:(CSFNetwork *)enqueuedNetwork {
    CSFNetwork *oldNetwork = _enqueuedNetwork;
    
    if (oldNetwork != enqueuedNetwork && oldNetwork) {
        [oldNetwork removeObserver:self forKeyPath:@"credentialsReady" context:kObservingKey];
    }
    
    [super setEnqueuedNetwork:enqueuedNetwork];
    
    if (enqueuedNetwork) {
        [enqueuedNetwork addObserver:self
                          forKeyPath:@"credentialsReady"
                             options:(NSKeyValueObservingOptionInitial |
                                      NSKeyValueObservingOptionNew)
                             context:kObservingKey];
    }
}

- (id)contentFromData:(NSData*)data fromResponse:(NSHTTPURLResponse*)response error:(NSError**)error {
    NSError *responseError = nil;
    id content = [super contentFromData:data fromResponse:response error:&responseError];

    if (content && !responseError) {
        NSObject *msgObj = nil;
        NSString *errorCode = nil;
        
        // TODO: I think this code can be cleaned up to be a bit more tidy.
        if ([content isKindOfClass:[NSArray class]] && [(NSArray*)content count] > 0) {
            NSArray *jsonArray = (NSArray*)content;
            NSDictionary *errorDict = jsonArray[0];
            if ([errorDict isKindOfClass:[NSDictionary class]] && errorDict[@"errorCode"]) {
                msgObj = errorDict[@"message"] ?: errorDict[@"msg"];
                errorCode = errorDict[@"errorCode"] ;
            }
        } else if (response.statusCode >= 400 && [content isKindOfClass:[NSDictionary class]]) {
            NSDictionary *errorDict = (NSDictionary*)content;
            msgObj = errorDict[@"msg"];
        }
        
        CSFNetwork *network = self.enqueuedNetwork;
        if (response.statusCode >= 400) {
            
            // Note: request session refresh only when the error indicates the session expired (see W-2005000)
            BOOL requestSessionRefresh = NO;
            switch (response.statusCode) {
                case 400:
                    // bad request (invalid URI / invalid params)
                    // The request could not be understood, usually because of an invalid ID, such as a userId, feedItemId,
                    // or groupId being incorrect.
                    break;
                    
                case 401:
                    // unauthorized (not logged in / session expired)
                    // The session ID or OAuth token used has expired or is invalid.
                    // The response body contains the message and errorCode.
                    if ([errorCode isEqualToString:@"INVALID_SESSION_ID"]) {
                        requestSessionRefresh = YES;
                    }
                    break;
                    
                case 403:
                    // forbidden (user isn't allowed to do the operation). The request has been refused.
                    // i.e. 'operation couldn't be completed'
                    
                    // With Connect, the server returns this error code when the device is no longer authorized on core.
                    if ([errorCode isEqualToString:@"CLIENT_NOT_ACCESSIBLE_FOR_USER"]) {
                        [network receivedDevicedUnauthorizedError:self];
                        //allow error to propagate on to the original caller as well-- allows for facade completions etc
                    }
                    break;
                    
                case 404:
                    // resource was not found or deleted
                    break;
                    
                case 408:
                    // request timeout
                    // request took too long and was aborted - max time per request is a setting, when last check, 120s
                    break;
                    
                case 503:
                    // unavailable - too many requests in an hour
                    // max concurrent requests hit - max concurrent requests is a setting, when last confirmed it was 50 per JVM)
                    break;
                    
                case 500:
                    // all other errors: "An error has occurred within Force.com"
                    // fall-through
                    
                default:
                    // When the user is revoked, the response object is nil (so error code is 0)
                    // but the errorObj contains the invalid session message that we need to handle.
                    if ([errorCode isEqualToString:@"INVALID_SESSION_ID"]) {
                        requestSessionRefresh = YES;
                    }
                    break;
            }
            
            NSString *errorDescription = [msgObj description] ?: [NSString stringWithFormat:@"HTTP %ld for %@ %@", (long)response.statusCode, self.method, self.verb];
            NSMutableDictionary *userInfoDict = [NSMutableDictionary dictionaryWithDictionary:@{ NSLocalizedDescriptionKey:errorDescription,
                                                                                                 CSFNetworkErrorActionKey: self,
                                                                                                 CSFNetworkErrorAuthenticationFailureKey: @(requestSessionRefresh) }
                                                 ];
            if (errorCode.length > 0) {
                userInfoDict[NSLocalizedFailureReasonErrorKey] = errorCode;
            }
            responseError = [NSError errorWithDomain:CSFNetworkErrorDomain
                                                code:response.statusCode
                                            userInfo:userInfoDict];
        }
        
        // TODO: We need to figure out how to handle the security token some other way, so it doesn't collide with other action types.
        if (!responseError && [content isKindOfClass:[NSDictionary class]]) {
            NSDictionary *jsonContent = (NSDictionary*)content;
            NSString *securityToken = jsonContent[CSFActionSecurityTokenKey]; // retrieve the CSRF security token
            if (securityToken) {
                network.securityToken = securityToken;
            }
        }
    }
    
    if (error) {
        *error = responseError;
    }

    return content;
}

- (NSString *)basePath {
    NSString *workingPathPrefix = ([self.pathPrefix length] == 0 ? @"" : self.pathPrefix);
    NSString *workingApiVersion = ([self.apiVersion length] == 0 ? @"" : self.apiVersion);
    NSString *returnBasePath = [workingPathPrefix stringByAppendingPathComponent:workingApiVersion];
    if ([returnBasePath hasSuffix:@"/"]) {
        returnBasePath = [returnBasePath substringToIndex:([returnBasePath length] - 1)];
    }
    return returnBasePath;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context == kObservingKey) {
        [self willChangeValueForKey:@"ready"];
        [self didChangeValueForKey:@"ready"];
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

- (BOOL)isEqualToAction:(CSFAction *)action {
    if (![action isKindOfClass:[CSFSalesforceAction class]]) {
        return NO;
    }
    
    if (![super isEqualToAction:action]) {
        return NO;
    }
    
    CSFSalesforceAction *salesforceAction = (CSFSalesforceAction *)action;
    if (!(salesforceAction.apiVersion == nil && self.apiVersion == nil) && ![self.apiVersion isEqualToString:salesforceAction.apiVersion]) {
        return NO;
    }
    if (!(salesforceAction.pathPrefix == nil && self.pathPrefix == nil) && ![self.pathPrefix isEqualToString:salesforceAction.pathPrefix]) {
        return NO;
    }
    
    return YES;
}

@end