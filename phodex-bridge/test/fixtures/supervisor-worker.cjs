// 仅用于监督进程测试：故意忽略 SIGTERM，验证两秒后的强制收口。
process.on('SIGTERM',()=>{});
process.stdin.resume();
console.log(process.pid);
setInterval(()=>{},1000);
