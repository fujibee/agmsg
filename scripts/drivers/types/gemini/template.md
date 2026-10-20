<!-- Gemini CLI overlay. -->
<!-- agmsg:slot delivery -->
<!-- agmsg:render-overlay __AGENT_TYPE__ -->
  5. 有効なdelivery modeが未設定で、利用者の選択もない場合にだけ、選択肢と影響を説明して回答を待つ。設定済みなら既存modeを保持する。 Choose `turn` or `off` delivery （未回答や空入力をmode設定の許可として扱わない）, then run `delivery.sh set <mode> __AGENT_TYPE__ "$(pwd)"`. Gemini has no monitor equivalent.
<!-- /agmsg:slot delivery -->
<!-- agmsg:slot mode -->
If argument is "mode", run `delivery.sh status __AGENT_TYPE__ "$(pwd)"`.
For `mode turn|off`, run `delivery.sh set <mode> __AGENT_TYPE__ "$(pwd)"`; reject `monitor` and `both`.
<!-- /agmsg:slot mode -->
