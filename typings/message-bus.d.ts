declare interface MessageBus {
  start(): void

  subscribe(channel: string, func: (payload?: any | void, globalId?: string | void, messageId?: string | void) => void, lastId?: number | void): void

  unsubscribe(channel?: string, func?: () => void): void

  pause(): void

  resume(): void

  stop(): void

  status(): void

  noConflict(): void

  diagnostics(): void

  enableLongPolling: boolean
  callbackInterval: number
  backgroundCallbackInterval: number
  minPollInterval: number
  maxPollInterval: number
  alwaysLongPoll: boolean
  baseUrl: string
  ajax: string
  headers: any
  minHiddenPollInterval: number
  enableChunkedEncoding: boolean
}


declare module 'messagebus' {
  export = MessageBus;
}

