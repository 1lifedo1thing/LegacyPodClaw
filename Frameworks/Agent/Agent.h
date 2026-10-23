/*
 * OCAgent.h
 * LegacyPodClaw - Lightweight Local Agent Runtime
 *
 * Inspired by PicoClaw's <10MB approach. Provides:
 * - Local agent execution with tool orchestration
 * - HTTP-based model routing to remote AI APIs
 * - MCP (Model Context Protocol) client support
 * - Context management with token budgets
 * - The device can run as both a gateway client AND a lightweight node
 *
 * On the iPod Touch 4 this enables basic local intelligence
 * even when gateway connectivity is intermittent.
 */

#import <Foundation/Foundation.h>
#import "Store.h"
#import "MemoryPool.h"

#pragma mark - Model Configuration

@interface OCModelConfig : NSObject
@property (nonatomic, copy) NSString *providerId;        // see OCProviderInfo, defaults to anthropic
@property (nonatomic, copy) NSString *modelId;           // empty means the provider default
@property (nonatomic, copy) NSString *apiKey;
@property (nonatomic, copy) NSString *baseURL;           // empty means the provider default
@property (nonatomic, assign) NSUInteger maxTokens;      // Response token limit
@property (nonatomic, assign) NSUInteger contextWindow;  // Total context budget
@end

/* who asked for a tool call, shown in the confirmation dialog */
typedef NS_ENUM(NSUInteger, OCToolCaller) {
    OCToolCallerChat = 0,
    OCToolCallerAgent,
    OCToolCallerRemote,
    /* text from a chat channel is untrusted, so every call it causes is confirmed on the device */
    OCToolCallerChannel,
};

#pragma mark - Tool Definition

typedef void(^OCToolResultBlock)(id result, NSError *error);
typedef void(^OCToolHandler)(NSDictionary *params, OCToolResultBlock callback);

@interface OCToolDefinition : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *toolDescription;
@property (nonatomic, copy) NSDictionary *inputSchema;   // JSON Schema
@property (nonatomic, copy) OCToolHandler handler;
@property (nonatomic, assign) BOOL requiresConfirmation;
@property (nonatomic, assign) NSTimeInterval timeout;    // Default 30s
@end

#pragma mark - Agent Message

typedef NS_ENUM(NSUInteger, OCAgentMessageRole) {
    OCAgentRoleSystem = 0,
    OCAgentRoleUser,
    OCAgentRoleAssistant,
    OCAgentRoleTool
};

@interface OCAgentMessage : NSObject
@property (nonatomic, assign) OCAgentMessageRole role;
@property (nonatomic, copy) NSString *content;
@property (nonatomic, copy) NSString *toolName;
@property (nonatomic, copy) NSString *toolCallId;
@property (nonatomic, copy) NSDictionary *toolInput;
@property (nonatomic, copy) id toolResult;
@property (nonatomic, assign) BOOL isError;
/* assistant turns: the tool calls the model made, and the provider blocks to send back unchanged */
@property (nonatomic, retain) NSArray *toolCalls;
@property (nonatomic, retain) NSArray *rawContent;
@property (nonatomic, assign) NSUInteger estimatedTokens;
+ (OCAgentMessage *)messageWithRole:(OCAgentMessageRole)role content:(NSString *)content;
@end

#pragma mark - Agent Delegate

@class OCAgent;

@protocol OCAgentDelegate <NSObject>
@required
- (void)agent:(OCAgent *)agent didProduceText:(NSString *)text isFinal:(BOOL)isFinal;
- (void)agent:(OCAgent *)agent didFailWithError:(NSError *)error;
@optional
- (void)agent:(OCAgent *)agent willInvokeTool:(NSString *)toolName
   withParams:(NSDictionary *)params;
- (void)agent:(OCAgent *)agent didInvokeTool:(NSString *)toolName
       result:(id)result;
- (void)agent:(OCAgent *)agent didStartThinking:(NSString *)thinking;
- (void)agent:(OCAgent *)agent tokenUsage:(NSUInteger)input output:(NSUInteger)output;
@end

#pragma mark - MCP Client

/*
 * Lightweight MCP (Model Context Protocol) client for connecting
 * to local or remote tool servers.
 */
@interface OCMCPClient : NSObject

@property (nonatomic, copy) NSString *serverURL;
@property (nonatomic, copy) NSString *serverName;
@property (nonatomic, readonly) BOOL isConnected;
@property (nonatomic, readonly) NSArray *availableTools;

- (instancetype)initWithURL:(NSString *)url name:(NSString *)name;

- (void)connect:(void(^)(BOOL success, NSError *error))callback;
- (void)disconnect;

- (void)callTool:(NSString *)toolName
          params:(NSDictionary *)params
        callback:(OCToolResultBlock)callback;

- (void)listTools:(void(^)(NSArray *tools, NSError *error))callback;

@end

#pragma mark - Agent Runtime

@interface OCAgent : NSObject

@property (nonatomic, assign) id<OCAgentDelegate> delegate;
@property (nonatomic, retain) OCModelConfig *modelConfig;
@property (nonatomic, copy) NSString *systemPrompt;
@property (nonatomic, readonly) BOOL isProcessing;
/* off sends no tools to the model; defaults to on */
@property (nonatomic, assign) BOOL toolsEnabled;
@property (nonatomic, assign) OCToolCaller toolCaller;

/* Token budget management */
@property (nonatomic, assign) NSUInteger maxContextTokens;  // Default 4096 (conservative)
@property (nonatomic, assign) NSUInteger maxResponseTokens;  // Default 1024
@property (nonatomic, readonly) NSUInteger currentContextTokens;

/* Tool management */
- (void)registerTool:(OCToolDefinition *)tool;
- (void)removeTool:(NSString *)toolName;
- (NSArray *)registeredTools;
/* registered tools plus mcp tools whose names do not clash with them */
- (NSArray *)availableTools;

/* MCP server connections */
- (void)addMCPServer:(OCMCPClient *)server;
- (void)removeMCPServer:(NSString *)serverName;

/* Run agent */
- (void)processMessage:(NSString *)userMessage;
- (void)abort;

/* Context management */
- (void)clearContext;
/* replaces the conversation with earlier turns, oldest first */
- (void)loadHistory:(NSArray *)messages;
- (void)addSystemMessage:(NSString *)message;
- (NSArray *)contextMessages;

/* Conversation memory - auto-compacts when over token budget */
- (void)compactContext;

/* Estimate tokens for a string (rough: chars/4) */
+ (NSUInteger)estimateTokens:(NSString *)text;

@end

#pragma mark - Built-in Tools

/*
 * Factory for device-local tools that can run on the iPod Touch.
 */
@interface OCBuiltinTools : NSObject

/* Returns array of OCToolDefinition for device-local tools */
+ (NSArray *)deviceTools;

/* Individual tools */
+ (OCToolDefinition *)dateTimeTool;
+ (OCToolDefinition *)deviceInfoTool;
+ (OCToolDefinition *)clipboardTool;
+ (OCToolDefinition *)httpFetchTool;
+ (OCToolDefinition *)fileReadTool;
+ (OCToolDefinition *)mathTool;
+ (OCToolDefinition *)timerTool;

@end
