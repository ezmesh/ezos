// Tiny DOM helpers. Vanilla TS, no JSX.

export function el<K extends keyof HTMLElementTagNameMap>(
    tag: K,
    attrs: Record<string, string | number | boolean | EventListener | null | undefined> = {},
    children: Array<Node | string | null | undefined> = [],
): HTMLElementTagNameMap[K] {
    const node = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs)) {
        if (v === null || v === undefined || v === false) continue;
        if (k.startsWith("on") && typeof v === "function") {
            node.addEventListener(k.slice(2).toLowerCase(), v as EventListener);
        } else if (k === "class") {
            node.className = String(v);
        } else if (k === "html") {
            node.innerHTML = String(v);
        } else if (v === true) {
            node.setAttribute(k, "");
        } else {
            node.setAttribute(k, String(v));
        }
    }
    for (const c of children) {
        if (c == null) continue;
        node.appendChild(typeof c === "string" ? document.createTextNode(c) : c);
    }
    return node;
}

export function clear(parent: HTMLElement) {
    while (parent.firstChild) parent.removeChild(parent.firstChild);
}

export function mount(parent: HTMLElement, ...nodes: Node[]) {
    clear(parent);
    for (const n of nodes) parent.appendChild(n);
}
