function literals(text){
 const result=[];let i=0;
 function quoted(start){let j=start+1,parts=[],plain='';while(j<text.length){if(text[j]==='"'){parts.push(plain);return {start,end:j+1,parts}}if(text[j]==='\\'&&text[j+1]==='('){parts.push(plain);plain='';let e=j+2,level=1;const a=e;while(e<text.length&&level){if(text[e]==='"'){e=quoted(e).end;continue}if(text[e]==='(')level++;if(text[e]===')')level--;if(level)e++}parts.push({expression:text.slice(a,e)});j=e+1;continue}if(text[j]==='\\'){plain+=text.slice(j,j+2);j+=2;continue}plain+=text[j++]};throw Error('Unclosed string')}
 while(i<text.length){if(text.startsWith('#"',i)){i=text.indexOf('"#',i+2);if(i<0)break;i+=2;continue}if(text.startsWith('//',i)){i=text.indexOf('\n',i);if(i<0)break;continue}if(text.startsWith('/*',i)){let depth=1;i+=2;while(depth&&i<text.length){if(text.startsWith('/*',i)){depth++;i+=2}else if(text.startsWith('*/',i)){depth--;i+=2}else i++}continue}if(text.startsWith('"""',i)){i=text.indexOf('"""',i+3);if(i<0)break;i+=3;continue}if(text[i]==='"'){const item=quoted(i);result.push(item);i=item.end}else i++}return result;
}
module.exports={literals};
