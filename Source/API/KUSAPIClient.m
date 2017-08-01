//
//  KUSAPIClient.m
//  Kustomer
//
//  Created by Daniel Amitay on 7/4/17.
//  Copyright © 2017 Kustomer. All rights reserved.
//

#import "KUSAPIClient.h"

static NSString *kKustomerTrackingTokenHeaderKey = @"x-kustomer-tracking-token";

@interface KUSAPIClient ()

@property (atomic, copy, readonly) NSString *orgName;
@property (atomic, copy, readonly) NSString *organizationName;  // User-facing (capitalized) version of orgName
@property (atomic, copy, readonly, nullable) NSString *trackingToken;
@property (atomic, copy, readonly) NSString *baseUrlString;
@property (atomic, strong, readonly) NSURLSession *urlSession;

@end

@implementation KUSAPIClient

static NSString *KUSAPIRequestTypeToString(KUSAPIRequestType type)
{
    switch (type) {
        case KUSAPIRequestTypeGet:
            return @"GET";
        case KUSAPIRequestTypePost:
            return @"POST";
        case KUSAPIRequestTypePatch:
            return @"PATCH";
        case KUSAPIRequestTypePut:
            return @"PUT";
        case KUSAPIRequestTypeDelete:
            return @"DELETE";
    }
}

static NSString *KUSBaseUrlStringFromOrgName(NSString *orgName)
{
    NSDictionary<NSString *, NSString *> *environment = [[NSProcessInfo processInfo] environment];
    NSString *baseDomain = environment[@"KUSTOMER_BASE_DOMAIN"] ?: @"kustomerapp.com";
    return [NSString stringWithFormat:@"https://%@.api.%@", orgName, baseDomain];
}

#pragma mark - Lifecycle methods

- (instancetype)initWithOrgName:(NSString *)orgName
{
    self = [super init];
    if (self) {
        _orgName = orgName;
        _trackingToken = [[NSUserDefaults standardUserDefaults] stringForKey:kKustomerTrackingTokenHeaderKey];
        _baseUrlString = KUSBaseUrlStringFromOrgName(_orgName);
        if (_orgName.length) {
            NSString *firstLetter = [[orgName substringToIndex:1] uppercaseString];
            _organizationName = [firstLetter stringByAppendingString:[orgName substringFromIndex:1]];
        }

        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
        [configuration setTimeoutIntervalForRequest:15.0];
        _urlSession = [NSURLSession sessionWithConfiguration:configuration delegate:nil delegateQueue:nil];

        [self _fetchLatestTrackingToken];
    }
    return self;
}

#pragma mark - Internal methods

- (void)_fetchLatestTrackingToken
{
    [self getCurrentTrackingToken:^(NSError *error, KUSTrackingToken *trackingToken) {
        if (error) {
            // TODO: Retry logic
            NSLog(@"Tracking token error: %@", error);
            return;
        }
        NSLog(@"Latest token: %@", trackingToken.token);
    }];
}

#pragma mark - Request methods

- (NSURL *)URLForEndpoint:(NSString *)endpoint
{
    NSString *endpointUrlString = [NSString stringWithFormat:@"%@/c%@", self.baseUrlString, endpoint];
    return [NSURL URLWithString:endpointUrlString];
}

- (NSURL *)URLForPath:(NSString *)path
{
    NSString *urlString = [NSString stringWithFormat:@"%@%@", self.baseUrlString, path];
    return [NSURL URLWithString:urlString];
}

- (void)performRequestType:(KUSAPIRequestType)type
                  endpoint:(NSString *)endpoint
                    params:(NSDictionary<NSString *, id> *)params
                completion:(void(^)(NSError *error, NSDictionary *response))completion
{
    NSURL *endpointURL = [self URLForEndpoint:endpoint];
    [self performRequestType:type URL:endpointURL params:params completion:completion];
}

- (void)performRequestType:(KUSAPIRequestType)type
                  URL:(NSURL *)URL
                    params:(NSDictionary<NSString *, id> *)params
                completion:(void(^)(NSError *error, NSDictionary *response))completion
{
    if (type == KUSAPIRequestTypeGet) {
        NSURLComponents *urlComponents = [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:NO];
        NSMutableArray<NSURLQueryItem *> *queryItems = [[NSMutableArray alloc] initWithCapacity:params.count];
        for (NSString *key in params) {
            id value = params[key];
            NSString *valueString = nil;
            if ([value isKindOfClass:[NSString class]]) {
                valueString = (NSString *)value;
            } else {
                valueString = [NSString stringWithFormat:@"%@", value];
            }
            NSURLQueryItem *queryItem = [NSURLQueryItem queryItemWithName:key value:valueString];
            [queryItems addObject:queryItem];
        }
        urlComponents.queryItems = queryItems;
        URL = urlComponents.URL;
    }

    NSMutableURLRequest *urlRequest = [[NSMutableURLRequest alloc] initWithURL:URL];
    [urlRequest setHTTPMethod:KUSAPIRequestTypeToString(type)];

    if (params && type != KUSAPIRequestTypeGet) {
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:params options:kNilOptions error:NULL];
        [urlRequest setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        NSString *contentLength = [NSString stringWithFormat:@"%lu", (unsigned long)jsonData.length];
        [urlRequest setValue:contentLength forHTTPHeaderField:@"Content-Length"];
        [urlRequest setHTTPBody:jsonData];
    }

    [self _performURLRequest:urlRequest completion:completion];
}

- (void)getEndpoint:(NSString *)endpoint completion:(void(^)(NSError *error, NSDictionary *response))completion
{
    [self performRequestType:KUSAPIRequestTypeGet endpoint:endpoint params:nil completion:completion];
}

- (void)postEndpoint:(NSString *)endpoint body:(NSDictionary *)body completion:(void(^)(NSError *error, NSDictionary *response))completion
{
    [self performRequestType:KUSAPIRequestTypePost endpoint:endpoint params:body completion:completion];
}

- (void)patchEndpoint:(NSString *)endpoint body:(NSDictionary *)body completion:(void(^)(NSError *error, NSDictionary *response))completion
{
    [self performRequestType:KUSAPIRequestTypePatch endpoint:endpoint params:body completion:completion];
}

- (void)putEndpoint:(NSString *)endpoint body:(NSDictionary *)body completion:(void(^)(NSError *error, NSDictionary *response))completion
{
    [self performRequestType:KUSAPIRequestTypePut endpoint:endpoint params:body completion:completion];
}

- (void)_performURLRequest:(NSMutableURLRequest *)urlRequest completion:(void(^)(NSError *error, NSDictionary *response))completion
{
    // Attach relevant headers
    [urlRequest setValue:@"kustomer" forHTTPHeaderField:@"X-Kustomer"];
    if (self.trackingToken) {
        [urlRequest setValue:self.trackingToken forHTTPHeaderField:kKustomerTrackingTokenHeaderKey];
    }

    void (^safeComplete)(NSError *, NSDictionary *) = ^void(NSError *error, NSDictionary *response) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (error) {
                    completion(error, nil);
                } else {
                    completion(nil, response);
                }
            });
        }
    };
    void (^responseBlock)(NSData *, NSURLResponse *, NSError *) = ^void(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            safeComplete(error, nil);
            return;
        }
        NSError *jsonError;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:&jsonError];
        safeComplete(jsonError, json);
    };
    NSURLSessionDataTask *dataTask = [_urlSession dataTaskWithRequest:urlRequest completionHandler:responseBlock];
    [dataTask resume];
}

#pragma mark -
#pragma mark Identity methods

- (void)getCurrentTrackingToken:(void(^)(NSError *error, KUSTrackingToken *trackingToken))completion
{
    [self getEndpoint:@"/v1/tracking/tokens/current" completion:^(NSError *error, NSDictionary *response) {
        KUSTrackingToken *trackingToken = [[KUSTrackingToken alloc] initWithJSON:response[@"data"]];
        if (trackingToken.token) {
            _trackingToken = trackingToken.token;
            [[NSUserDefaults standardUserDefaults] setObject:_trackingToken forKey:kKustomerTrackingTokenHeaderKey];
        }
        if (completion) {
            completion(error, trackingToken);
        }
    }];
}

- (void)describe:(NSDictionary *)description completion:(void(^)(NSError *error, KUSCustomer *customer))completion
{
    [self patchEndpoint:@"/v1/customers/current" body:description completion:^(NSError *error, NSDictionary *response) {
        KUSCustomer *customer = [[KUSCustomer alloc] initWithJSON:response[@"data"]];
        if (completion) {
            completion(error, customer);
        }
    }];
}

- (void)identify:(NSDictionary *)identity completion:(void(^)(NSError *error))completion
{
    [self postEndpoint:@"/v1/identity" body:identity completion:^(NSError *error, NSDictionary *response) {
        // TODO: Determine response (KUSTrackingToken?)
        if (completion) {
            completion(error);
        }
    }];
}

- (void)clearTrackingToken:(void(^)(NSError *error, KUSTrackingToken *trackingToken))completion
{
    [self postEndpoint:@"/v1/tracking/tokens" body:@{} completion:^(NSError *error, NSDictionary *response) {
        KUSTrackingToken *trackingToken = [[KUSTrackingToken alloc] initWithJSON:response[@"data"]];
        if (trackingToken.token) {
            _trackingToken = trackingToken.token;
            [[NSUserDefaults standardUserDefaults] setObject:_trackingToken forKey:kKustomerTrackingTokenHeaderKey];
        }
        if (completion) {
            completion(error, trackingToken);
        }
    }];
}

- (void)getChatSettings:(void(^)(NSError *error, KUSChatSettings *chatSettings))completion
{
    [self getEndpoint:@"/v1/chat/settings" completion:^(NSError *error, NSDictionary *response) {
        KUSChatSettings *chatSettings = [[KUSChatSettings alloc] initWithJSON:response[@"data"]];
        if (completion) {
            completion(error, chatSettings);
        }
    }];
}

#pragma mark Sessions methods

- (void)getChatSessions:(void(^)(NSError *error, KUSPaginatedResponse *chatSessions))completion
{
    [self getEndpoint:@"/v1/chat/sessions" completion:^(NSError *error, NSDictionary *response) {
        KUSPaginatedResponse *chatSessionsResponse = [[KUSPaginatedResponse alloc] initWithJSON:response modelClass:[KUSChatSession class]];
        if (completion) {
            completion(error, chatSessionsResponse);
        }
    }];
}

- (void)getChatSessionFoId:(NSString *)sessionId completion:(void(^)(NSError *error, KUSChatSession *session))completion
{
    NSString *endpoint = [NSString stringWithFormat:@"/v1/chat/sessions/%@", sessionId];
    [self getEndpoint:endpoint completion:^(NSError *error, NSDictionary *response) {
        KUSChatSession *chatSession = [[KUSChatSession alloc] initWithJSON:response[@"data"]];
        if (completion) {
            completion(error, chatSession);
        }
    }];
}

- (void)createChatSessionWithTitle:(NSString *)title completion:(void(^)(NSError *error, KUSChatSession *session))completion
{
    NSDictionary *payload = @{ @"title": title };
    [self postEndpoint:@"/v1/chat/sessions" body:payload completion:^(NSError *error, NSDictionary *response) {
        KUSChatSession *chatSession = [[KUSChatSession alloc] initWithJSON:response[@"data"]];
        if (completion) {
            completion(error, chatSession);
        }
    }];
}

- (void)updateLastSeenAtForSessionId:(NSString *)sessionId completion:(void(^)(NSError *error, KUSChatSession *session))completion
{
    NSString *endpoint = [NSString stringWithFormat:@"/v1/chat/sessions/%@/messages", sessionId];
    // TODO: Convert NSData to ISO8601 NSString using NSDateFormatter
    NSDictionary *payload = @{ @"lastSeenAt": @"2017-07-05T04:41:17.310Z" };
    [self putEndpoint:endpoint body:payload completion:^(NSError *error, NSDictionary *response) {
        KUSChatSession *chatSession = [[KUSChatSession alloc] initWithJSON:response[@"data"]];
        if (completion) {
            completion(error, chatSession);
        }
    }];
}

#pragma mark Messages methods

- (void)getMessagesForSessionId:(NSString *)sessionId completion:(void(^)(NSError *error, KUSPaginatedResponse *chatMessages))completion
{
    NSString *endpoint = [NSString stringWithFormat:@"/v1/chat/sessions/%@/messages", sessionId];
    [self getEndpoint:endpoint completion:^(NSError *error, NSDictionary *response) {
        KUSPaginatedResponse *chatMessagesResponse = [[KUSPaginatedResponse alloc] initWithJSON:response modelClass:[KUSChatMessage class]];
        if (completion) {
            completion(error, chatMessagesResponse);
        }
    }];
}

- (void)sendMessage:(NSString *)message toChatSession:(NSString *)sessionId completion:(void(^)(NSError *error, KUSChatMessage *message))completion
{
    NSDictionary *payload = @{ @"body": message, @"session": sessionId };
    [self postEndpoint:@"/v1/chat/messages" body:payload completion:^(NSError *error, NSDictionary *response) {
        KUSChatMessage *chatMessage = [[KUSChatMessage alloc] initWithJSON:response[@"data"]];
        if (completion) {
            completion(error, chatMessage);
        }
    }];
}

@end