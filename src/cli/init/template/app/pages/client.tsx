import { useState } from "react";

export default function Page(props: { count: number }) {
    const [count, setCount] = useState(props.count);

    return (
        <div>
            <button onClick={reset}>Reset</button>
            <h5>{count}</h5>
            <button onClick={decrement}>Decrement</button>
            <button onClick={increment}>Increment</button>
        </div>
    );

    function increment() {
        setCount(c => c + 1);
        fetch(`?increment=true`);
    }

    function decrement() {
        setCount(c => c - 1);
        fetch(`?decrement=true`);
    }

    function reset() {
        setCount(0);
        fetch(`?reset=true`);
    }
}