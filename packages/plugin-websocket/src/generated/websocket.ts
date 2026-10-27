// Generated from Zig service types. Protocol version 1.
export type Methods = {
"connect": { params: { "id": number; "url": string; "protocols": ReadonlyArray<string>; "headers": ReadonlyArray<{ "name": string; "value": string; }>; }; result: undefined; error: "invalid" | "denied" | "busy" | "closed" | "failed"; item: { "kind": "open" | "text" | "binary" | "close"; "protocol": (string | null); "data": (string | null); "last": boolean; "code": number; "reason": (string | null); "clean": boolean; "error": (string | null); } };
"send": { params: { "id": number; "kind": "text" | "binary" | "close"; "data": (string | null); "last": boolean; "code": number; "reason": (string | null); }; result: undefined; error: "invalid" | "denied" | "busy" | "closed" | "failed"; item: never };
};
const methodSpecs: Record<keyof Methods, Spec> = {
["connect"]: { stream: true, params: {kind:'object',fields:[{name:"id",optional:false,shape:{kind:'number',integer:true,min:0,max:4294967295}},{name:"url",optional:false,shape:{kind:'string'}},{name:"protocols",optional:false,shape:{kind:'array',child:{kind:'string'}}},{name:"headers",optional:false,shape:{kind:'array',child:{kind:'object',fields:[{name:"name",optional:false,shape:{kind:'string'}},{name:"value",optional:false,shape:{kind:'string'}}]}}}]}, result: {kind:'void'}, item: {kind:'object',fields:[{name:"kind",optional:false,shape:{kind:'enum',values:["open","text","binary","close"]}},{name:"protocol",optional:false,shape:{kind:'optional',child:{kind:'string'}}},{name:"data",optional:false,shape:{kind:'optional',child:{kind:'string'}}},{name:"last",optional:false,shape:{kind:'bool'}},{name:"code",optional:false,shape:{kind:'number',integer:true,min:0,max:65535}},{name:"reason",optional:false,shape:{kind:'optional',child:{kind:'string'}}},{name:"clean",optional:false,shape:{kind:'bool'}},{name:"error",optional:false,shape:{kind:'optional',child:{kind:'string'}}}]}, errors: ["invalid","denied","busy","closed","failed"] },
["send"]: { stream: false, params: {kind:'object',fields:[{name:"id",optional:false,shape:{kind:'number',integer:true,min:0,max:4294967295}},{name:"kind",optional:false,shape:{kind:'enum',values:["text","binary","close"]}},{name:"data",optional:false,shape:{kind:'optional',child:{kind:'string'}}},{name:"last",optional:false,shape:{kind:'bool'}},{name:"code",optional:false,shape:{kind:'number',integer:true,min:0,max:65535}},{name:"reason",optional:false,shape:{kind:'optional',child:{kind:'string'}}}]}, result: {kind:'void'}, item: {kind:'void'}, errors: ["invalid","denied","busy","closed","failed"] },
};
export type Events = {
};
const eventSpecs: Record<keyof Events, Shape> = {
};
export class LocalError extends Error {
  constructor(readonly code: string) { super(code); this.name = "LocalError"; }
}
export class RemoteError<Code extends string = string> extends Error {
  constructor(readonly code: Code, message: string) { super(message); this.name = "RemoteError"; }
}
export interface Call<Result, Code extends string> {
  readonly result: Promise<Result>;
  readonly error: RemoteError<Code> | null;
  cancel(): void;
}
export interface Stream<Result, Item, Code extends string> extends Call<Result, Code>, AsyncIterable<Item> {}
export interface Connection {
  receive(message: string): void;
  close(): void;
  readonly pendingCount: number;
}
export interface EventConnection {
  readonly listenerCount: number;
  readonly subscriptionCount: number;
  on<K extends keyof Events>(event: K, callback: (value: Events[K]) => void): () => void;
}
export type Client = Connection & (keyof Events extends never ? {} : EventConnection) & {
  [K in keyof Methods]: (...args: [Methods[K]["params"]] extends [undefined] ? [params?: undefined] : [params: Methods[K]["params"]]) =>
    [Methods[K]["item"]] extends [never]
      ? Call<Methods[K]["result"], Methods[K]["error"]>
      : Stream<Methods[K]["result"], Methods[K]["item"], Methods[K]["error"]>;
};
type Shape = {
  kind: "void" | "bool" | "number" | "string" | "enum" | "optional" | "array" | "object";
  integer?: boolean; min?: number; max?: number; length?: number; child?: Shape;
  values?: readonly string[]; fields?: readonly { name: string; optional: boolean; shape: Shape }[];
};
type Spec = { stream: boolean; params: Shape; result: Shape; item: Shape; errors: readonly string[] };
type Chunk = { sequence: number; value: unknown };
type EventState = { subscription: number; count: number };
type Listener = { event: keyof Events; serial: number; index: number; callback: (value: unknown) => void;
  previous?: Listener; next?: Listener };
type Pending = {
  id: number; slot: number; spec: Spec; done: boolean; received: number;
  buffer: (Chunk | undefined)[]; head: number; length: number; failure?: Error;
  waiter?: { resolve: (value: IteratorResult<unknown>) => void; reject: (error: Error) => void };
  resolve: (value: unknown) => void; reject: (error: Error) => void;
};

function utf8Length(text: string): number {
  let bytes = 0;
  for (let i = 0; i < text.length; i++) {
    const value = text.charCodeAt(i);
    if (value < 0x80) bytes++;
    else if (value < 0x800) bytes += 2;
    else if (value >= 0xd800 && value <= 0xdbff) {
      const low = text.charCodeAt(++i);
      if (!(low >= 0xdc00 && low <= 0xdfff)) return Infinity;
      bytes += 4;
    } else if (value >= 0xdc00 && value <= 0xdfff) return Infinity;
    else bytes += 3;
  }
  return bytes;
}
function valid(shape: Shape, value: unknown): boolean {
  switch (shape.kind) {
    case "void": return value === undefined || value === null;
    case "bool": return typeof value === "boolean";
    case "number": return typeof value === "number" && Number.isFinite(value) &&
      (!shape.integer || Number.isSafeInteger(value)) &&
      (shape.min === undefined || value >= shape.min) && (shape.max === undefined || value <= shape.max);
    case "string": return typeof value === "string" && Number.isFinite(utf8Length(value)) &&
      (shape.length === undefined || utf8Length(value) === shape.length);
    case "enum": return typeof value === "string" && shape.values!.includes(value);
    case "optional": return value === null || valid(shape.child!, value);
    case "array": return Array.isArray(value) && (shape.length === undefined || value.length === shape.length) &&
      value.every((item) => valid(shape.child!, item));
    case "object": {
      if (typeof value !== "object" || value === null || Array.isArray(value)) return false;
      const object = value as Record<string, unknown>;
      const fields = shape.fields!;
      return Object.keys(object).every((name) => fields.some((field) => field.name === name)) &&
        fields.every((field) => Object.hasOwn(object, field.name) && object[field.name] !== undefined
          ? valid(field.shape, object[field.name]) : field.optional);
    }
  }
}

/** Transport sends one JSON string synchronously or throws before accepting it.
 * The host and page must use matching limits and a fresh host-issued session.
 * receive is called explicitly by the owner; no event listener or timer is hidden.
 */
export function createClient(post: (message: string) => void, session: string,
  options: { maxPending?: number; maxInFlight?: number; maxMessageBytes?: number;
    maxSubscriptions?: number; maxEventListeners?: number } = {}): Client {
  if (!/^[0-9a-f]{32}$/.test(session)) throw new LocalError("InvalidSession");
  const capacity = options.maxPending ?? 32;
  const window = options.maxInFlight ?? 8;
  const maxBytes = options.maxMessageBytes ?? 65536;
  const maxSubscriptions = options.maxSubscriptions ?? 32;
  const maxListeners = options.maxEventListeners ?? 64;
  if (![capacity, window, maxBytes, maxSubscriptions, maxListeners].every((value) => Number.isSafeInteger(value) && value > 0) ||
      capacity > 65535 || window > 65535 || maxSubscriptions > 65535 || maxListeners > 65535) throw new LocalError("InvalidLimits");
  const slots: (Pending | undefined)[] = new Array(capacity);
  const free = Array.from({ length: capacity }, (_, index) => capacity - index - 1);
  let sequence = 0;
  let closed = false;
  const eventNames = Object.keys(eventSpecs);
  const eventStates = Object.create(null) as Record<string, EventState>;
  for (const name of eventNames) eventStates[name] = { subscription: 0, count: 0 };
  const listeners: (Listener | undefined)[] = new Array(maxListeners);
  let listenerCount = 0, subscriptionCount = 0, eventSequence = 0, listenerSequence = 0;
  let dispatchingEvent = false;
  let firstListener: Listener | undefined, lastListener: Listener | undefined, eventCursor: Listener | undefined;
  const ignoreEvent = () => {};

  const clearListeners = () => {
    for (const entry of listeners) if (entry) {
      entry.previous = undefined; entry.next = undefined; entry.callback = ignoreEvent;
    }
    listeners.fill(undefined); listenerCount = 0;
    firstListener = undefined; lastListener = undefined; eventCursor = undefined;
  };
  const unlink = (entry: Listener) => {
    if (eventCursor === entry) eventCursor = entry.next;
    if (entry.previous) entry.previous.next = entry.next; else firstListener = entry.next;
    if (entry.next) entry.next.previous = entry.previous; else lastListener = entry.previous;
    entry.previous = undefined; entry.next = undefined; entry.callback = ignoreEvent;
    listeners[entry.index] = undefined; listenerCount--;
  };

  const clearEvents = () => {
    clearListeners(); subscriptionCount = 0;
    for (const name of eventNames) { eventStates[name].subscription = 0; eventStates[name].count = 0; }
  };

  const release = (entry: Pending) => {
    if (slots[entry.slot] !== entry) return;
    slots[entry.slot] = undefined;
    free.push(entry.slot);
  };
  const finish = (entry: Pending, error?: Error, value?: unknown) => {
    if (entry.done) return;
    entry.done = true;
    entry.failure = error;
    release(entry);
    if (error) {
      entry.buffer.fill(undefined); entry.length = 0;
      entry.reject(error);
      entry.waiter?.reject(error);
    } else {
      entry.resolve(value);
      entry.waiter?.resolve({ done: true, value: undefined });
    }
    entry.waiter = undefined;
  };
  const stop = (error: Error) => {
    closed = true;
    clearEvents();
    for (const entry of slots) if (entry) finish(entry, error);
  };
  const send = (message: object) => {
    const text = JSON.stringify({ v: 1, session, ...message });
    if (utf8Length(text) > maxBytes) throw new LocalError("MessageTooLarge");
    try { post(text); } catch (error) {
      const failure = error instanceof Error ? error : new LocalError("TransportFailed");
      stop(failure);
      throw failure;
    }
  };
  const cancel = (entry: Pending) => {
    if (entry.done) return;
    finish(entry, new LocalError("Cancelled"));
    try { send({ kind: "cancel", slot: entry.slot, id: entry.id }); }
    catch (error) { stop(error instanceof Error ? error : new LocalError("TransportFailed")); }
  };
  const acknowledge = (entry: Pending, chunk: Chunk) => {
    if (entry.done) return;
    try { send({ kind: "ack", slot: entry.slot, id: entry.id, sequence: chunk.sequence }); }
    catch (error) { stop(error instanceof Error ? error : new LocalError("TransportFailed")); }
  };
  const invoke = (name: keyof Methods, params: unknown): Call<unknown, string> | Stream<unknown, unknown, string> => {
    if (closed) throw new LocalError("Closed");
    const spec = methodSpecs[name] as Spec;
    if (!valid(spec.params, params)) throw new LocalError("InvalidParams");
    if (free.length === 0) throw new LocalError("Full");
    if (sequence === 0xffffffff) throw new LocalError("RequestIdExhausted");
    const slot = free.pop()!;
    let resolve!: Pending["resolve"], reject!: Pending["reject"];
    const result = new Promise<unknown>((accept, fail) => { resolve = accept; reject = fail; });
    // Iterating a failed stream must not also create an unhandled result rejection.
    void result.catch(() => {});
    const entry: Pending = { id: ++sequence, slot, spec, done: false,
      received: 0, buffer: spec.stream ? new Array(window) : [], head: 0, length: 0, resolve, reject };
    slots[slot] = entry;
    const call: Stream<unknown, unknown, string> = {
      result, get error() { return entry.failure instanceof RemoteError ? entry.failure : null; },
      cancel: () => cancel(entry),
      [Symbol.asyncIterator]() {
        return {
          next() {
            if (entry.length > 0) {
              const chunk = entry.buffer[entry.head]!;
              entry.buffer[entry.head] = undefined;
              entry.head = (entry.head + 1) % window;
              entry.length--;
              acknowledge(entry, chunk);
              return Promise.resolve({ value: chunk.value, done: false });
            }
            if (entry.failure) return Promise.reject(entry.failure);
            if (entry.done) return Promise.resolve({ value: undefined, done: true });
            if (entry.waiter) return Promise.reject(new LocalError("ConcurrentRead"));
            return new Promise<IteratorResult<unknown>>((accept, fail) => { entry.waiter = { resolve: accept, reject: fail }; });
          },
          return() {
            cancel(entry); entry.buffer.fill(undefined); entry.length = 0;
            return Promise.resolve({ value: undefined, done: true });
          },
        };
      },
    };
    try { send({ kind: "call", slot, id: entry.id, method: name, params }); }
    catch (error) { finish(entry, error instanceof Error ? error : new LocalError("TransportFailed")); }
    return call;
  };
  const connection: Connection & EventConnection = {
    get pendingCount() { return capacity - free.length; },
    get listenerCount() { return listenerCount; },
    get subscriptionCount() { return subscriptionCount; },
    on<K extends keyof Events>(name: K, callback: (value: Events[K]) => void) {
      if (closed) throw new LocalError("Closed");
      if (!Object.hasOwn(eventSpecs, name) || typeof callback !== "function") throw new LocalError("InvalidEvent");
      if (listenerCount === maxListeners) throw new LocalError("ListenerFull");
      const state = eventStates[name];
      const first = state.count === 0;
      if (first && subscriptionCount === maxSubscriptions) throw new LocalError("SubscriptionFull");
      if (first && eventSequence === 0xffffffff) throw new LocalError("SubscriptionIdExhausted");
      if (listenerSequence === Number.MAX_SAFE_INTEGER) throw new LocalError("ListenerIdExhausted");
      const index = listeners.findIndex((entry) => entry === undefined);
      const entry: Listener = { event: name, serial: ++listenerSequence, index,
        previous: lastListener, callback: callback as (value: unknown) => void };
      if (lastListener) lastListener.next = entry; else firstListener = entry;
      lastListener = entry;
      listeners[index] = entry; listenerCount++; state.count++;
      if (first) { state.subscription = ++eventSequence; subscriptionCount++; }
      const subscription = state.subscription;
      if (first) {
        try { send({ kind: "subscribe", event: name, subscription }); }
        catch (failure) {
          // Size failure happens before transport acceptance and does not close
          // existing RPCs. A transport failure already cleared all local state.
          if (listeners[index] === entry) {
            unlink(entry); state.count--;
            state.subscription = 0; subscriptionCount--;
          }
          throw failure;
        }
      }
      return () => {
        if (listeners[index] !== entry) return;
        unlink(entry); state.count--;
        if (state.count !== 0) return;
        state.subscription = 0; subscriptionCount--;
        if (closed) return;
        try { send({ kind: "unsubscribe", event: name, subscription }); }
        catch (failure) {
          stop(failure instanceof Error ? failure : new LocalError("TransportFailed"));
          throw failure;
        }
      };
    },
    close() {
      if (closed) return;
      closed = true;
      clearListeners();
      for (const name of eventNames) {
        const state = eventStates[name], subscription = state.subscription;
        state.subscription = 0; state.count = 0;
        if (!subscription) continue;
        subscriptionCount--;
        try { send({ kind: "unsubscribe", event: name, subscription }); }
        catch (failure) { stop(failure instanceof Error ? failure : new LocalError("TransportFailed")); break; }
      }
      const error = new LocalError("Closed");
      for (const entry of slots) if (entry) {
        finish(entry, error);
        try { send({ kind: "cancel", slot: entry.slot, id: entry.id }); }
        catch (failure) { stop(failure instanceof Error ? failure : new LocalError("TransportFailed")); break; }
      }
    },
    receive(text: string) {
      if (closed) return;
      let event: { name: keyof Events; subscription: number; value: unknown } | undefined;
      try {
        if (utf8Length(text) > maxBytes) throw new LocalError("MessageTooLarge");
        const frame = JSON.parse(text) as Record<string, unknown>;
        if (typeof frame !== "object" || frame === null || Array.isArray(frame)) throw new LocalError("InvalidMessage");
        if (frame.session !== session) return;
        if (frame.kind === "event") {
          if (frame.v !== 1 || typeof frame.event !== "string" || !Object.hasOwn(eventSpecs, frame.event) ||
              !Number.isInteger(frame.subscription) || (frame.subscription as number) < 1 ||
              (frame.subscription as number) > 0xffffffff ||
              Object.keys(frame).some((key) => !["v", "session", "kind", "event", "subscription", "value"].includes(key))) throw new LocalError("InvalidEvent");
          const name = frame.event as keyof Events;
          if (eventStates[name].subscription !== frame.subscription) return;
          const shape = eventSpecs[name] as Shape;
          if (!valid(shape, frame.value)) throw new LocalError("InvalidEvent");
          event = { name, subscription: frame.subscription as number,
            value: shape.kind === "void" ? undefined : frame.value };
        } else {
        if (frame.v !== 1 || !Number.isInteger(frame.slot) || !Number.isInteger(frame.id) ||
            (frame.slot as number) < 0 || (frame.slot as number) >= capacity ||
            (frame.id as number) < 1 || (frame.id as number) > 0xffffffff) throw new LocalError("InvalidMessage");
        const entry = slots[frame.slot as number];
        if (!entry || entry.id !== frame.id) return;
        switch (frame.kind) {
          case "result":
            if (!valid(entry.spec.result, frame.value)) throw new LocalError("InvalidResult");
            finish(entry, undefined, entry.spec.result.kind === "void" ? undefined : frame.value); break;
          case "error": {
            const error = frame.error as Record<string, unknown> | undefined;
            if (!error || typeof error.code !== "string" || typeof error.message !== "string" ||
                !entry.spec.errors.includes(error.code)) throw new LocalError("InvalidError");
            finish(entry, new RemoteError(error.code, error.message)); break;
          }
          case "reject":
            if (typeof frame.code !== "string") throw new LocalError("InvalidError");
            finish(entry, new LocalError(frame.code)); break;
          case "chunk": {
            if (!entry.spec.stream || frame.sequence !== entry.received + 1 ||
                !valid(entry.spec.item, frame.value) || entry.length >= window) throw new LocalError("InvalidChunk");
            entry.received++;
            const chunk: Chunk = { sequence: entry.received, value: frame.value };
            if (entry.waiter) {
              const waiter = entry.waiter; entry.waiter = undefined;
              waiter.resolve({ done: false, value: chunk.value });
              acknowledge(entry, chunk);
            } else {
              entry.buffer[(entry.head + entry.length) % window] = chunk;
              entry.length++;
            }
            break;
          }
          default: throw new LocalError("InvalidMessage");
        }
        }
      } catch (error) { stop(error instanceof Error ? error : new LocalError("InvalidMessage")); return; }
      if (!event) return;
      // Subscription mutations and close are allowed in callbacks. Additions
      // start at the next event; removals take effect before their next turn.
      // Nested event delivery is rejected without a hidden queue or RPC failure.
      if (dispatchingEvent) throw new LocalError("ReentrantEvent");
      dispatchingEvent = true;
      const fence = listenerSequence;
      eventCursor = firstListener;
      let failed = false, failure: unknown;
      try {
        while (eventCursor) {
          if (closed || eventStates[event.name].subscription !== event.subscription) break;
          const entry: Listener = eventCursor;
          eventCursor = entry.next;
          if (entry.event !== event.name || entry.serial > fence) continue;
          try { entry.callback(event.value); }
          catch (error) { if (!failed) { failed = true; failure = error; } }
        }
      } finally { dispatchingEvent = false; eventCursor = undefined; }
      if (failed) throw failure;
    },
  };
  const client: Record<string, unknown> = Object.assign(Object.create(null) as Record<string, unknown>, connection);
  // Preserve the live getter instead of copying its current numeric value.
  Object.defineProperty(client, "pendingCount", { get: () => connection.pendingCount });
  if (eventNames.length) {
    Object.defineProperty(client, "listenerCount", { get: () => connection.listenerCount });
    Object.defineProperty(client, "subscriptionCount", { get: () => connection.subscriptionCount });
  }
  for (const name of Object.keys(methodSpecs) as (keyof Methods)[]) client[name] = (params: unknown) => invoke(name, params);
  return client as unknown as Client;
}
