/*
 * HTTPFetch.h
 * LegacyPodClaw - one entry point for http and https requests
 *
 * https goes through CPTLSClient, because SecureTransport on iOS 6 lacks the
 * ciphers many servers now require. Plain http (a LAN proxy, Ollama) uses
 * NSURLConnection. Every other scheme, such as file://, is refused.
 */

#import <Foundation/Foundation.h>

/* runs on the main queue; status is 0 when the request did not complete */
typedef void(^CPFetchCompletion)(NSData *data, NSInteger status, NSError *error);

void CPFetch(NSString *urlString, NSString *method, NSDictionary *headers, NSData *body,
             NSTimeInterval timeout, CPFetchCompletion completion);

/* posts a json object and parses a json reply; json is nil on any failure */
void CPFetchJSON(NSString *urlString, NSDictionary *headers, id jsonBody, NSTimeInterval timeout,
                 void (^completion)(id json, NSInteger status, NSError *error));

/* sends an existing NSURLRequest through CPFetch, keeping its method, headers, body and timeout */
void CPFetchRequest(NSURLRequest *request, CPFetchCompletion completion);
