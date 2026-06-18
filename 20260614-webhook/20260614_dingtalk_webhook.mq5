//+------------------------------------------------------------------+
//|                                   20260614_dingtalk_webhook.mq5  |
//+------------------------------------------------------------------+
#property copyright "DingTalk Account Monitor"
#property version   "1.28"
#property description "账户快照推送: EA启停、开仓、平仓"

input group "=== 钉钉推送 ==="
input string InpWebhookUrl = "https://oapi.dingtalk.com/robot/send?access_token=4db833b5fb337ffb7ba596176a0e4117bb83fef1b6f2d58f603b08fedacfe123"; // 钉钉Webhook地址
input string InpSecret     = "";                    // 加签密钥(未开启加签可留空)
input string InpKeyword    = "ea";                  // 关键词(须与机器人安全设置一致)
input string InpAccountDisplay = "";               // 账户展示(留空=login@server)

//+------------------------------------------------------------------+
//| DingTalk helpers (inlined)                                       |
//+------------------------------------------------------------------+

string DtJsonEscape(const string text)
{
   string s=text;
   StringReplace(s,"\\","\\\\");
   StringReplace(s,"\"","\\\"");
   StringReplace(s,"\n","\\n");
   return s;
}

string DtUrlEncode(const string text)
{
   uchar bytes[];
   int n=StringToCharArray(text,bytes,0,WHOLE_ARRAY,CP_UTF8);
   if(n<=1) return "";
   string out="";
   string unreserved="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~";
   for(int i=0;i<n-1;i++){
      uchar b=bytes[i];
      string ch=CharToString((uchar)b);
      if(StringFind(unreserved,ch)>=0) out+=ch; else out+=StringFormat("%%%02X",b);
   }
   return out;
}

bool DtSha256(const uchar &data[],uchar &hash[])
{
   uchar key_empty[];
   ArrayResize(hash,0);
   return CryptEncode(CRYPT_HASH_SHA256,data,key_empty,hash)>0;
}

bool DtHmacSha256(const uchar &key[],const uchar &msg[],uchar &out[])
{
   uchar k[64]; ArrayInitialize(k,0);
   int key_len=ArraySize(key);
   if(key_len>64){
      uchar key_hash[]; if(!DtSha256(key,key_hash)) return false;
      ArrayCopy(k,key_hash,0,0,MathMin(32,ArraySize(key_hash))); key_len=32;
   } else ArrayCopy(k,key,0,0,key_len);
   uchar ipad[64],opad[64];
   for(int i=0;i<64;i++){ uchar b=(i<key_len)?k[i]:0; ipad[i]=(uchar)(b^0x36); opad[i]=(uchar)(b^0x5c); }
   uchar inner[]; ArrayResize(inner,64+ArraySize(msg));
   ArrayCopy(inner,ipad,0,0,64); ArrayCopy(inner,msg,64,0);
   uchar inner_hash[]; if(!DtSha256(inner,inner_hash)) return false;
   uchar outer[]; ArrayResize(outer,64+ArraySize(inner_hash));
   ArrayCopy(outer,opad,0,0,64); ArrayCopy(outer,inner_hash,64,0);
   uchar key_empty[]; ArrayResize(out,0);
   return CryptEncode(CRYPT_HASH_SHA256,outer,key_empty,out)>0;
}

string DtBase64Encode(const uchar &data[])
{
   uchar enc[],key_empty[];
   int n=CryptEncode(CRYPT_BASE64,data,key_empty,enc);
   if(n<=0) return "";
   string s=CharArrayToString(enc,0,n);
   StringReplace(s,"\r",""); StringReplace(s,"\n","");
   return s;
}

string DtTrim(const string text){ string s=text; StringTrimLeft(s); StringTrimRight(s); return s; }

string DtAccountLabel()
{
   return IntegerToString((long)AccountInfoInteger(ACCOUNT_LOGIN))+"@"+AccountInfoString(ACCOUNT_SERVER);
}

string DtMetaAccountLine()
{
   string custom=DtTrim(InpAccountDisplay);
   if(custom=="") return DtAccountLabel();
   return custom;
}

string DtFmtMoney(const double value,const int digits=2)
{
   return DoubleToString(value,digits);
}
string DtFmtProfitSigned(const double value)
{
   if(value>0.0) return "+"+DtFmtMoney(value);
   return DtFmtMoney(value);
}

string DtSideTag(const string side)
{
   if(side=="BUY") return "📈 BUY";
   if(side=="SELL") return "📉 SELL";
   return side;
}

string DtIndexTag(const int idx)
{
   string tags[]={"①","②","③","④","⑤","⑥","⑦","⑧","⑨","⑩"};
   if(idx>=1 && idx<=10) return tags[idx-1];
   return IntegerToString(idx)+".";
}

string DtBuildMarkdownMetaAccount()
{
   string s="> 🏦 **"+DtMetaAccountLine()+"**  \n\n";
   return s;
}

string DtBuildMarkdownTitle(const string keyword,const string event_name)
{
   return DtTrim(keyword)+" "+DtTrim(event_name);
}

string DtPushTimeFull()
{
   return TimeToString(TimeLocal(),TIME_DATE|TIME_SECONDS);
}

string DtBuildPushTitle(const string keyword,const string card_name,const string event_label)
{
   return DtBuildMarkdownTitle(keyword,card_name)+" · "+event_label;
}

string DtAppendSendFooter(string text,const string push_time)
{
   text+="  \n  \n> "+push_time+"  \n";
   return text;
}

string DtGenMsgUuid()
{
   return IntegerToString((long)AccountInfoInteger(ACCOUNT_LOGIN))+"_"
         +IntegerToString((long)GetTickCount64())+"_"
         +IntegerToString((long)TimeLocal());
}
string DtFmtPrice(const double price,const string symbol)
{
   int digits=(int)SymbolInfoInteger(symbol,SYMBOL_DIGITS);
   if(digits<=0) digits=_Digits;
   return DoubleToString(price,digits);
}

string DtPositionSideText(const long pos_type)
{
   if(pos_type==POSITION_TYPE_BUY) return "BUY";
   if(pos_type==POSITION_TYPE_SELL) return "SELL";
   return "POS";
}

string DtClosedPositionSide(const long deal_type)
{
   if(deal_type==DEAL_TYPE_SELL) return "BUY";
   if(deal_type==DEAL_TYPE_BUY) return "SELL";
   return "?";
}

string DtSymbolShort(const string symbol)
{
   string s=symbol;
   int dot=StringFind(s,".");
   if(dot>0) s=StringSubstr(s,0,dot);
   int us=StringFind(s,"_");
   if(us>0) s=StringSubstr(s,0,us);
   if(StringLen(s)<=3) return s;
   return StringSubstr(s,0,3);
}

double DtSumFloatingProfit()
{
   double sum=0.0;
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      sum+=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP)+PositionGetDouble(POSITION_COMMISSION);
   }
   return sum;
}

int DtCountPositions()
{
   return PositionsTotal();
}

string DtBuildPositionBody()
{
   string text="";
   int total=PositionsTotal();
   if(total<=0){
      text+="> _暂无持仓_  \n";
      return text;
   }
   text+="| 品种 | 方向 | 手数 | 盈亏 | 魔 |  \n";
   text+="| :--- | :---: | :---: | :---: | :---: |  \n";
   for(int i=total-1;i>=0;i--){
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      string symbol=PositionGetString(POSITION_SYMBOL);
      string side=DtPositionSideText(PositionGetInteger(POSITION_TYPE));
      double lots=PositionGetDouble(POSITION_VOLUME);
      long pos_magic=(long)PositionGetInteger(POSITION_MAGIC);
      double profit=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP)+PositionGetDouble(POSITION_COMMISSION);
      text+="| "+DtSymbolShort(symbol)+" | "+side+" | "+DoubleToString(lots,2)+" | "+DtFmtProfitSigned(profit)+" | "+IntegerToString(pos_magic)+" |  \n";
   }
   return text;
}

string DtBuildMarkdownAccountSummary(const string keyword,const string event_label)
{
   double balance=AccountInfoDouble(ACCOUNT_BALANCE);
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   double floating=DtSumFloatingProfit();
   int pos_count=DtCountPositions();

   string text="#### 📊 "+DtBuildPushTitle(keyword,"账户快照",event_label)+"  \n\n";
   text+=DtBuildMarkdownMetaAccount();
   text+="##### 💰 资金概览  \n";
   text+="> 结余 **"+DtFmtMoney(balance)+"**  \n";
   text+="> 净值 **"+DtFmtMoney(equity)+"**  \n";
   text+="> 浮盈(亏) **"+DtFmtProfitSigned(floating)+"**  \n";
   text+="> 持仓 **"+IntegerToString(pos_count)+"** 笔  \n";
   return text;
}

string DtBuildMarkdownPositionList(const string keyword,const string event_label)
{
   string text="#### 📋 "+DtBuildPushTitle(keyword,"持仓明细",event_label)+"  \n\n";
   text+=DtBuildMarkdownMetaAccount();
   text+=DtBuildPositionBody();
   return text;
}

string DtBuildMarkdownCloseDetail(const string keyword,const string event_label,const ulong deal_ticket)
{
   string text="#### 📤 "+DtBuildPushTitle(keyword,"平仓明细",event_label)+"  \n\n";
   text+=DtBuildMarkdownMetaAccount();
   if(!HistoryDealSelect(deal_ticket)){
      text+="> _无平仓数据_  \n";
      return text;
   }
   long entry=HistoryDealGetInteger(deal_ticket,DEAL_ENTRY);
   if(entry!=DEAL_ENTRY_OUT && entry!=DEAL_ENTRY_INOUT){
      text+="> _无平仓数据_  \n";
      return text;
   }
   string symbol=HistoryDealGetString(deal_ticket,DEAL_SYMBOL);
   string side=DtClosedPositionSide(HistoryDealGetInteger(deal_ticket,DEAL_TYPE));
   double volume=HistoryDealGetDouble(deal_ticket,DEAL_VOLUME);
   long magic=(long)HistoryDealGetInteger(deal_ticket,DEAL_MAGIC);
   double profit=HistoryDealGetDouble(deal_ticket,DEAL_PROFIT)
               +HistoryDealGetDouble(deal_ticket,DEAL_SWAP)
               +HistoryDealGetDouble(deal_ticket,DEAL_COMMISSION);
   text+="| 品种 | 方向 | 手数 | 盈亏 | 魔 |  \n";
   text+="| :--- | :---: | :---: | :---: | :---: |  \n";
   text+="| "+DtSymbolShort(symbol)+" | "+side+" | "+DoubleToString(volume,2)+" | "+DtFmtProfitSigned(profit)+" | "+IntegerToString(magic)+" |  \n";
   return text;
}

string DtBuildUrl(const string webhook_url,const string secret,string &err)
{
   err="";
   string url=DtTrim(webhook_url), sec=DtTrim(secret);
   if(url==""){ err="Webhook empty"; return ""; }
   if(StringFind(url,"https://oapi.dingtalk.com/robot/send")!=0){ err="Bad webhook url"; return ""; }
   if(sec=="") return url;
   long ts=(long)TimeGMT()*1000;
   string sign_src=IntegerToString(ts)+"\n"+sec;
   uchar key[],msg[];
   StringToCharArray(sec,key,0,WHOLE_ARRAY,CP_UTF8); if(ArraySize(key)>0) ArrayResize(key,ArraySize(key)-1);
   StringToCharArray(sign_src,msg,0,WHOLE_ARRAY,CP_UTF8); if(ArraySize(msg)>0) ArrayResize(msg,ArraySize(msg)-1);
   uchar sign_bytes[]; if(!DtHmacSha256(key,msg,sign_bytes)){ err="HMAC failed"; return ""; }
   return url+"&timestamp="+IntegerToString(ts)+"&sign="+DtUrlEncode(DtBase64Encode(sign_bytes));
}

bool DtSendMarkdown(const string webhook_url,const string secret,
                    const string title,const string markdown_text,
                    string &resp,int &code,string &err)
{
   resp=""; code=-1; err="";
   if(MQLInfoInteger(MQL_TESTER)){ err="No WebRequest in tester"; return false; }
   string url=DtBuildUrl(webhook_url,secret,err); if(url=="") return false;
   string msg_uuid=DtGenMsgUuid();
   string body="{\"msgtype\":\"markdown\",\"msgUuid\":\""+DtJsonEscape(msg_uuid)+"\",\"markdown\":{\"title\":\""+DtJsonEscape(title)+"\",\"text\":\""+DtJsonEscape(markdown_text)+"\"}}";
   uchar post[]; int plen=StringToCharArray(body,post,0,WHOLE_ARRAY,CP_UTF8); if(plen>0) ArrayResize(post,plen-1);
   uchar result[]; string rh, headers="Content-Type: application/json; charset=utf-8\r\n";
   ResetLastError();
   code=WebRequest("POST",url,headers,15000,post,result,rh);
   resp=CharArrayToString(result,0,WHOLE_ARRAY,CP_UTF8);
   if(code==-1){ err=StringFormat("WebRequest err=%d, add https://oapi.dingtalk.com",GetLastError()); return false; }
   if(code!=200){ err="HTTP "+IntegerToString(code); return false; }
   if(StringFind(resp,"\"errcode\":0")<0){ err=resp; return false; }
   return true;
}
bool SendMarkdownMsg(const string title,const string md_text,const string log_tag)
{
   string resp="", err=""; int code=-1;
   bool ok=DtSendMarkdown(InpWebhookUrl,InpSecret,title,md_text,resp,code,err);
   Print("DingTalk [",log_tag,"] ",ok?"OK":"FAIL", ok?"":(" "+err));
   if(resp!="") Print("HTTP=",code," ",resp);
   return ok;
}

bool SendAccountSnapshot(const string event_label)
{
   if(DtTrim(InpKeyword)==""){
      Print("DingTalk skip: keyword empty");
      return false;
   }

   string push_time1=DtPushTimeFull();
   string title_summary=DtBuildPushTitle(InpKeyword,"账户快照",event_label);
   string md_summary=DtBuildMarkdownAccountSummary(InpKeyword,event_label);
   md_summary=DtAppendSendFooter(md_summary,push_time1);

   bool ok_summary=SendMarkdownMsg(title_summary,md_summary,event_label+"-账户");
   Sleep(300);

   string push_time2=DtPushTimeFull();
   string title_positions=DtBuildPushTitle(InpKeyword,"持仓明细",event_label);
   string md_positions=DtBuildMarkdownPositionList(InpKeyword,event_label);
   md_positions=DtAppendSendFooter(md_positions,push_time2);

   bool ok_positions=SendMarkdownMsg(title_positions,md_positions,event_label+"-持仓");
   return ok_summary && ok_positions;
}

bool SendCloseDetail(const string event_label,const ulong deal_ticket)
{
   if(DtTrim(InpKeyword)=="") return false;
   Sleep(300);
   string push_time=DtPushTimeFull();
   string title=DtBuildPushTitle(InpKeyword,"平仓明细",event_label);
   string md=DtBuildMarkdownCloseDetail(InpKeyword,event_label,deal_ticket);
   md=DtAppendSendFooter(md,push_time);
   return SendMarkdownMsg(title,md,event_label+"-平仓");
}

int OnInit()
{
   SendAccountSnapshot("EA启动");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   SendAccountSnapshot("EA停止");
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD)
      return;
   ulong deal_ticket=trans.deal;
   if(deal_ticket==0)
      return;
   if(!HistoryDealSelect(deal_ticket))
      return;

   long entry=HistoryDealGetInteger(deal_ticket,DEAL_ENTRY);
   if(entry==DEAL_ENTRY_IN)
      SendAccountSnapshot("开仓");
   else if(entry==DEAL_ENTRY_OUT){
      SendAccountSnapshot("平仓");
      SendCloseDetail("平仓",deal_ticket);
   }
   else if(entry==DEAL_ENTRY_INOUT){
      SendAccountSnapshot("开平仓");
      SendCloseDetail("开平仓",deal_ticket);
   }
}