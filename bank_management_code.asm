; ============================================================
;   BANKING SYSTEM - EMU8086 ASSEMBLY  (FIXED v3)
;   File : banking_fixed.asm
;   Assembler : EMU8086 (8086 DOS)
;   Storage : accounts.txt  (username,pin,balance per line)
;
;   MAIN MENU            BANKING MENU
;   1. Create Account    1. Deposit Money
;   2. Login             2. Withdraw Money
;   3. Exit              3. Balance Inquiry
;                        4. Logout
;
; ============================================================
;  FIX LOG
; ============================================================
;  1.  All PROC have NEAR qualifier.
;  2.  PrintStr name collision (MACRO + PROC) -> renamed to
;      _PrintSI PROC + PRINTZ macro.
;  3.  "CALL PrintStr OFFSET lgUser" -> PRINTZ lgUser.
;  4.  FlushBalance rewritten (fBuf[CX] illegal, logic broken).
;  5.  FindUser: fBuf[CX] -> fBuf[BX].
;  6.  [DX] indirect addressing (illegal on 8086) -> [SI].
;  7.  ReadNum / ParseNum: MUL BX clobbered DX -> shift-add x10.
;  8.  *** MENU "INVALID CHOICE" BUG FIXED ***
;      GetChar (INT 21h/01h) reads ONE char. When the user types
;      '1' then presses ENTER, GetChar captures '1' but the CR
;      (13) stays in the DOS keyboard buffer. The very next call
;      to GetChar in the menu loop reads that leftover CR, which
;      matches no valid option and prints "Invalid option!" every
;      single time before the real choice is processed.
;      FIX: Added DrainKbd procedure. After every menu GetChar
;      call, DrainKbd reads and discards chars from the buffer
;      until it consumes the CR (or finds the buffer empty via
;      INT 21h/0Bh check-status trick). This flushes the ENTER
;      keypress so the next GetChar gets the user's real input.
;  9.  EmitCRLF after GetChar in menus removed (DrainKbd already
;      moves to the next line by consuming the CR/LF).
;      A single CRLF is printed by DrainKbd after draining.
; ============================================================

.MODEL SMALL
.STACK 200h

; ============================================================
;                   DATA SEGMENT
; ============================================================
.DATA

;--- File ---
fname       DB  'accounts.txt', 0
fHandle     DW  0

;--- File buffer (holds entire accounts.txt in memory, 2 KB) ---
fBuf        DB  2048 DUP('$')
fBufLen     DW  0

;--- Temp rebuild buffer used by FlushBalance ---
tmpBuf      DB  2048 DUP(0)

;--- Logged-in user state ---
lgUser      DB  21 DUP(0)   ; username (max 20 chars + null)
lgPin       DB   6 DUP(0)   ; pin      (4 digits + null)
lgBal       DW  0           ; current balance
lgLine      DW  0           ; byte offset of user's line in fBuf

;--- Input scratch ---
inUser      DB  21 DUP(0)
inPin       DB   6 DUP(0)
inAmt       DB   6 DUP(0)

;--- Number-to-string scratch ---
nBuf        DB   7 DUP(0)

;--- Messages ($-terminated for INT 21h / AH=09h) ---
mMain       DB  13,10
            DB  '============================',13,10
            DB  '     BANKING SYSTEM         ',13,10
            DB  '============================',13,10
            DB  ' 1. Create Account',13,10
            DB  ' 2. Login',13,10
            DB  ' 3. Exit',13,10
            DB  '----------------------------',13,10
            DB  'Choice: $'

mBank       DB  13,10
            DB  '============================',13,10
            DB  '      BANKING MENU          ',13,10
            DB  '============================',13,10
            DB  ' 1. Deposit Money',13,10
            DB  ' 2. Withdraw Money',13,10
            DB  ' 3. Balance Inquiry',13,10
            DB  ' 4. Logout',13,10
            DB  '----------------------------',13,10
            DB  'Choice: $'

mEnterUser  DB  13,10,'  Username : $'
mEnterPin   DB  13,10,'  PIN      : $'
mEnterAmt   DB  13,10,'  Amount   : $'

mCreated    DB  13,10,'  [OK] Account created successfully!',13,10,'$'
mDepOk      DB  13,10,'  [OK] Deposit successful!',13,10,'$'
mWitOk      DB  13,10,'  [OK] Withdrawal successful!',13,10,'$'
mBal        DB  13,10,'  Balance  : $'
mInsuff     DB  13,10,'  [ERR] Insufficient balance!',13,10,'$'
mBadPin     DB  13,10,'  [ERR] Invalid PIN!',13,10,'$'
mNoAcc      DB  13,10,'  [ERR] Account not found!',13,10,'$'
mExists     DB  13,10,'  [ERR] Username already exists!',13,10,'$'
mBadOpt     DB  13,10,'  [ERR] Invalid option!',13,10,'$'
mBye        DB  13,10,'  Goodbye! Thank you for banking with us.',13,10,'$'
mWelcome    DB  13,10,'  Welcome, $'
mNL         DB  13,10,'$'
mExclaim    DB  '!',13,10,'$'

; ============================================================
;                   MACROS
; ============================================================

; PRINT addr -- print a $-terminated string (INT 21h/09h)
PRINT MACRO addr
    LEA  DX, addr
    MOV  AH, 09h
    INT  21h
ENDM

; PRINTZ addr -- print a null-terminated string via _PrintSI
PRINTZ MACRO addr
    MOV  SI, OFFSET addr
    CALL _PrintSI
ENDM

; ============================================================
;                   CODE SEGMENT
; ============================================================
.CODE

; ===========================================================
; MAIN
; ===========================================================
MAIN PROC NEAR
    MOV  AX, @DATA
    MOV  DS, AX
    MOV  ES, AX

    CALL LoadFile           ; load accounts.txt into fBuf

MAIN_LOOP:
    PRINT mMain             ; show main menu
    CALL GetChar            ; read choice into AL (echoes char)
    CALL DrainKbd           ; *** FIX #8: flush leftover CR from buffer ***

    CMP  AL, '1'
    JE   MM_CREATE
    CMP  AL, '2'
    JE   MM_LOGIN
    CMP  AL, '3'
    JE   MM_EXIT
    PRINT mBadOpt
    JMP  MAIN_LOOP

MM_CREATE:
    CALL CreateAccount
    JMP  MAIN_LOOP

MM_LOGIN:
    CALL Login
    JMP  MAIN_LOOP

MM_EXIT:
    PRINT mBye
    MOV  AH, 4Ch
    INT  21h
MAIN ENDP

; ===========================================================
; CreateAccount
; ===========================================================
CreateAccount PROC NEAR
    ;--- Read username ---
    PRINT mEnterUser
    CALL ReadStr20          ; result -> inUser

    ;--- Check for duplicate ---
    MOV  SI, OFFSET inUser
    CALL FindUser           ; BX = line offset, or 0FFFFh if not found
    CMP  BX, 0FFFFh
    JE   CA_NEW
    PRINT mExists
    RET

CA_NEW:
    ;--- Read PIN ---
    PRINT mEnterPin
    CALL ReadPin4           ; result -> inPin

    ;--- Append "username,pin,0\r\n" to fBuf ---
    MOV  DI, fBufLen        ; DI = current write position

    ; copy username
    MOV  SI, OFFSET inUser
CA_U:
    MOV  AL, [SI]
    CMP  AL, 0
    JE   CA_U_END
    MOV  fBuf[DI], AL
    INC  SI
    INC  DI
    JMP  CA_U
CA_U_END:
    MOV  fBuf[DI], ','
    INC  DI

    ; copy pin
    MOV  SI, OFFSET inPin
CA_P:
    MOV  AL, [SI]
    CMP  AL, 0
    JE   CA_P_END
    MOV  fBuf[DI], AL
    INC  SI
    INC  DI
    JMP  CA_P
CA_P_END:
    MOV  fBuf[DI], ','
    INC  DI

    ; balance = 0
    MOV  fBuf[DI], '0'
    INC  DI
    MOV  fBuf[DI], 13       ; CR
    INC  DI
    MOV  fBuf[DI], 10       ; LF
    INC  DI
    MOV  fBuf[DI], 0        ; null-terminate buffer
    MOV  fBufLen, DI        ; update buffer length

    CALL SaveFile
    PRINT mCreated
    RET
CreateAccount ENDP

; ===========================================================
; Login
; ===========================================================
Login PROC NEAR
    ;--- Get username ---
    PRINT mEnterUser
    CALL ReadStr20          ; -> inUser

    MOV  SI, OFFSET inUser
    CALL FindUser           ; BX = line-start offset, or 0FFFFh
    CMP  BX, 0FFFFh
    JNE  LG_FOUND
    PRINT mNoAcc
    RET

LG_FOUND:
    ;--- Get PIN ---
    PRINT mEnterPin
    CALL ReadPin4           ; -> inPin

    ;--- Verify PIN against stored value ---
    ; BX = line start; skip past "username," to reach stored PIN
    MOV  SI, BX
LG_SKU:
    MOV  AL, fBuf[SI]
    INC  SI
    CMP  AL, ','
    JNE  LG_SKU
    ; SI now at first char of stored PIN

    MOV  DI, OFFSET inPin
LG_CMP:
    MOV  AL, fBuf[SI]
    CMP  AL, ','
    JE   LG_CMP_END
    CMP  AL, 13
    JE   LG_CMP_END
    CMP  AL, 0
    JE   LG_CMP_END
    MOV  AH, [DI]           ; [DI] is legal (DI is a valid pointer reg)
    CMP  AL, AH
    JNE  LG_BADPIN
    INC  SI
    INC  DI
    JMP  LG_CMP

LG_CMP_END:
    ; Typed PIN must also be exhausted
    CMP  BYTE PTR [DI], 0
    JNE  LG_BADPIN

    ;--- PIN matched: skip comma, parse stored balance ---
    INC  SI                 ; skip ','
    CALL ParseNum           ; AX = balance, SI advances
    MOV  lgBal, AX

    ;--- Save user state ---
    CALL CopyInUserToLg
    MOV  lgLine, BX

    ;--- Welcome ---
    PRINT mWelcome
    PRINTZ lgUser
    PRINT mExclaim

    ;--- Banking menu ---
    CALL BankMenu
    RET

LG_BADPIN:
    PRINT mBadPin
    RET
Login ENDP

; ===========================================================
; BankMenu
; ===========================================================
BankMenu PROC NEAR
BK_LOOP:
    PRINT mBank
    CALL GetChar            ; read choice
    CALL DrainKbd           ; *** FIX #8: flush leftover CR ***

    CMP  AL, '1'
    JE   BK_DEP
    CMP  AL, '2'
    JE   BK_WIT
    CMP  AL, '3'
    JE   BK_BAL
    CMP  AL, '4'
    JE   BK_OUT
    PRINT mBadOpt
    JMP  BK_LOOP

BK_DEP:
    CALL Deposit
    JMP  BK_LOOP
BK_WIT:
    CALL Withdraw
    JMP  BK_LOOP
BK_BAL:
    CALL BalInquiry
    JMP  BK_LOOP
BK_OUT:
    RET
BankMenu ENDP

; ===========================================================
; Deposit
; ===========================================================
Deposit PROC NEAR
    PRINT mEnterAmt
    CALL ReadNum            ; AX = amount
    ADD  lgBal, AX
    CALL FlushBalance
    PRINT mDepOk
    RET
Deposit ENDP

; ===========================================================
; Withdraw
; ===========================================================
Withdraw PROC NEAR
    PRINT mEnterAmt
    CALL ReadNum            ; AX = amount
    CMP  lgBal, AX
    JAE  WD_OK
    PRINT mInsuff
    RET
WD_OK:
    SUB  lgBal, AX
    CALL FlushBalance
    PRINT mWitOk
    RET
Withdraw ENDP

; ===========================================================
; BalInquiry
; ===========================================================
BalInquiry PROC NEAR
    PRINT mBal
    MOV  AX, lgBal
    CALL PrintNum
    PRINT mNL
    RET
BalInquiry ENDP

; ===========================================================
; FlushBalance
;   Rebuilds fBuf line-by-line into tmpBuf.
;   When the logged-in user's line is found, emits the
;   updated balance instead of the old value.
;   Copies tmpBuf back to fBuf and calls SaveFile.
; ===========================================================
FlushBalance PROC NEAR
    PUSH AX
    PUSH BX
    PUSH CX
    PUSH DX
    PUSH SI
    PUSH DI

    MOV  SI, 0              ; read  index into fBuf
    MOV  DI, 0              ; write index into tmpBuf

FB_LINE:
    MOV  AL, fBuf[SI]
    CMP  AL, 0
    JE   FB_DONE

    ; skip stray CR/LF
    CMP  AL, 13
    JE   FB_SKIP_CHAR
    CMP  AL, 10
    JE   FB_SKIP_CHAR
    JMP  FB_TRY_MATCH

FB_SKIP_CHAR:
    INC  SI
    JMP  FB_LINE

FB_TRY_MATCH:
    ; BX walks fBuf from line start for comparison.
    ; PUSH SI so we can borrow SI for the lgUser pointer
    ; (DX is NOT a legal indirect register on 8086).
    PUSH SI
    MOV  BX, SI
    MOV  SI, OFFSET lgUser

FB_MATCH_LOOP:
    MOV  AL, fBuf[BX]       ; char from file
    MOV  AH, [SI]           ; char from lgUser  -- SI is legal
    CMP  AH, 0              ; end of lgUser?
    JE   FB_MATCH_CHK
    CMP  AL, AH
    JNE  FB_MISMATCH
    INC  BX
    INC  SI
    JMP  FB_MATCH_LOOP

FB_MATCH_CHK:
    CMP  AL, ','            ; file must be at comma for true match
    JNE  FB_MISMATCH
    POP  SI                 ; discard saved SI (stack balance)
    JMP  FB_MATCHED

FB_MISMATCH:
    POP  SI                 ; restore SI = line-start read pointer
    JMP  FB_COPY_LINE

FB_MATCHED:
    ; Emit: lgUser,lgPin,newBalance\r\n into tmpBuf

    ; -- username --
    MOV  BX, OFFSET lgUser
FB_E_USR:
    MOV  AL, [BX]
    CMP  AL, 0
    JE   FB_E_USR_END
    MOV  tmpBuf[DI], AL
    INC  BX
    INC  DI
    JMP  FB_E_USR
FB_E_USR_END:
    MOV  tmpBuf[DI], ','
    INC  DI

    ; -- pin --
    MOV  BX, OFFSET lgPin
FB_E_PIN:
    MOV  AL, [BX]
    CMP  AL, 0
    JE   FB_E_PIN_END
    MOV  tmpBuf[DI], AL
    INC  BX
    INC  DI
    JMP  FB_E_PIN
FB_E_PIN_END:
    MOV  tmpBuf[DI], ','
    INC  DI

    ; -- new balance --
    MOV  AX, lgBal
    CALL Num2Str            ; -> nBuf
    MOV  BX, OFFSET nBuf
FB_E_BAL:
    MOV  AL, [BX]
    CMP  AL, 0
    JE   FB_E_BAL_END
    MOV  tmpBuf[DI], AL
    INC  BX
    INC  DI
    JMP  FB_E_BAL
FB_E_BAL_END:
    MOV  tmpBuf[DI], 13
    INC  DI
    MOV  tmpBuf[DI], 10
    INC  DI

    ; Skip old line in fBuf (advance SI past its LF)
FB_SKIP_OLD:
    MOV  AL, fBuf[SI]
    INC  SI
    CMP  AL, 10
    JNE  FB_SKIP_OLD
    JMP  FB_LINE

    ; Copy non-matching line verbatim into tmpBuf
FB_COPY_LINE:
FB_COPY_CHAR:
    MOV  AL, fBuf[SI]
    CMP  AL, 0
    JE   FB_DONE
    MOV  tmpBuf[DI], AL
    INC  SI
    INC  DI
    CMP  AL, 10
    JNE  FB_COPY_CHAR
    JMP  FB_LINE

FB_DONE:
    MOV  tmpBuf[DI], 0      ; null-terminate tmpBuf

    ; Copy tmpBuf back into fBuf
    MOV  SI, 0
    MOV  BX, 0
FB_COPYBACK:
    MOV  AL, tmpBuf[SI]
    MOV  fBuf[BX], AL
    INC  SI
    INC  BX
    CMP  AL, 0
    JNE  FB_COPYBACK

    DEC  BX
    MOV  fBufLen, BX

    CALL SaveFile

    POP  DI
    POP  SI
    POP  DX
    POP  CX
    POP  BX
    POP  AX
    RET
FlushBalance ENDP

; ===========================================================
; SkipToComma  - advance SI past next comma in fBuf
; ===========================================================
SkipToComma PROC NEAR
STC_LOOP:
    MOV  AL, fBuf[SI]
    INC  SI
    CMP  AL, ','
    JNE  STC_LOOP
    RET
SkipToComma ENDP

; ===========================================================
; FindUser
;   Input : DS:SI = null-terminated username to find
;   Output: BX = byte offset of line start, or 0FFFFh
; ===========================================================
FindUser PROC NEAR
    MOV  BX, 0

FU_LINE:
    MOV  AL, fBuf[BX]
    CMP  AL, 0
    JE   FU_FAIL
    CMP  AL, 13
    JE   FU_SKIP_CHAR
    CMP  AL, 10
    JE   FU_SKIP_CHAR
    JMP  FU_COMPARE

FU_SKIP_CHAR:
    INC  BX
    JMP  FU_LINE

FU_COMPARE:
    PUSH BX                 ; save line-start
    MOV  DI, SI             ; DI = input username pointer

FU_CMP_LOOP:
    MOV  AL, fBuf[BX]       ; BX is legal index register
    MOV  AH, [DI]           ; DI is legal index register
    CMP  AH, 0
    JE   FU_CHK
    CMP  AL, AH
    JNE  FU_MISMATCH
    INC  BX
    INC  DI
    JMP  FU_CMP_LOOP

FU_CHK:
    CMP  AL, ','
    JE   FU_FOUND

FU_MISMATCH:
    POP  BX
    JMP  FU_NEXT_LINE

FU_FOUND:
    POP  BX                 ; BX = line start
    RET

FU_NEXT_LINE:
FU_NL:
    MOV  AL, fBuf[BX]
    CMP  AL, 0
    JE   FU_FAIL
    INC  BX
    CMP  AL, 10
    JNE  FU_NL
    JMP  FU_LINE

FU_FAIL:
    MOV  BX, 0FFFFh
    RET
FindUser ENDP

; ===========================================================
; LoadFile  -  read accounts.txt into fBuf
; ===========================================================
LoadFile PROC NEAR
    MOV  AH, 3Dh
    MOV  AL, 00h
    LEA  DX, fname
    INT  21h
    JC   LF_EMPTY

    MOV  fHandle, AX
    MOV  AH, 3Fh
    MOV  BX, fHandle
    MOV  CX, 2047
    LEA  DX, fBuf
    INT  21h
    JC   LF_CLOSE
    MOV  fBufLen, AX
    MOV  SI, AX
    MOV  fBuf[SI], 0

LF_CLOSE:
    MOV  AH, 3Eh
    MOV  BX, fHandle
    INT  21h
    RET

LF_EMPTY:
    MOV  fBufLen, 0
    MOV  fBuf[0], 0
    RET
LoadFile ENDP

; ===========================================================
; SaveFile  -  write fBuf back to accounts.txt
; ===========================================================
SaveFile PROC NEAR
    MOV  AH, 3Ch
    MOV  CX, 0
    LEA  DX, fname
    INT  21h
    JC   SF_DONE

    MOV  fHandle, AX
    MOV  AH, 40h
    MOV  BX, fHandle
    MOV  CX, fBufLen
    LEA  DX, fBuf
    INT  21h

    MOV  AH, 3Eh
    MOV  BX, fHandle
    INT  21h
SF_DONE:
    RET
SaveFile ENDP

; ===========================================================
; CopyInUserToLg  -  copy inUser->lgUser, inPin->lgPin
; ===========================================================
CopyInUserToLg PROC NEAR
    MOV  SI, OFFSET inUser
    MOV  DI, OFFSET lgUser
CU_L:
    MOV  AL, [SI]
    MOV  [DI], AL
    INC  SI
    INC  DI
    CMP  AL, 0
    JNE  CU_L

    MOV  SI, OFFSET inPin
    MOV  DI, OFFSET lgPin
CU_P:
    MOV  AL, [SI]
    MOV  [DI], AL
    INC  SI
    INC  DI
    CMP  AL, 0
    JNE  CU_P
    RET
CopyInUserToLg ENDP

; ===========================================================
; DrainKbd  *** NEW - FIX #8 ***
;   Purpose : After GetChar reads the user's menu digit, the
;             ENTER key (CR = 13) that follows sits in the DOS
;             keyboard buffer.  Without draining it, the next
;             GetChar call in the menu loop reads that CR and
;             triggers "Invalid option!" on every single press.
;
;   Method  : Loop using INT 21h / AH=0Bh (check keyboard
;             status). If a char is waiting, read and discard
;             it with AH=08h (no-echo read). Stop when either
;             we consume a CR or the buffer reports empty.
;             Then print a CR LF so the cursor moves to a new
;             line (replacing the old EmitCRLF after GetChar).
;
;   Registers: AX only (saved/restored around the CRLF output).
; ===========================================================
DrainKbd PROC NEAR
    PUSH AX

DK_CHECK:
    MOV  AH, 0Bh            ; check keyboard status
    INT  21h                ; AL = FFh if char waiting, 00h if empty
    CMP  AL, 0
    JE   DK_CRLF            ; buffer empty -> done draining

    MOV  AH, 08h            ; read char WITHOUT echo (discard it)
    INT  21h
    CMP  AL, 13             ; was it the CR (ENTER)?
    JE   DK_CRLF            ; yes -> done
    JMP  DK_CHECK           ; no  -> keep draining

DK_CRLF:
    ; Move cursor to next line (visual feedback after choice)
    MOV  DL, 13
    MOV  AH, 02h
    INT  21h
    MOV  DL, 10
    INT  21h

    POP  AX
    RET
DrainKbd ENDP

; ===========================================================
; ReadStr20  -  read up to 20 chars into inUser  (CR = done)
; ===========================================================
ReadStr20 PROC NEAR
    MOV  DI, OFFSET inUser
    MOV  CX, 0
RS_L:
    CALL GetChar
    CMP  AL, 13
    JE   RS_DONE
    CMP  AL, 8
    JE   RS_BS
    CMP  CX, 20
    JAE  RS_L
    MOV  [DI], AL
    INC  DI
    INC  CX
    JMP  RS_L
RS_BS:
    CMP  CX, 0
    JE   RS_L
    DEC  DI
    DEC  CX
    JMP  RS_L
RS_DONE:
    MOV  BYTE PTR [DI], 0
    CALL EmitCRLF
    RET
ReadStr20 ENDP

; ===========================================================
; ReadPin4  -  read up to 4 chars into inPin  (CR = done)
; ===========================================================
ReadPin4 PROC NEAR
    MOV  DI, OFFSET inPin
    MOV  CX, 0
RP_L:
    CALL GetChar
    CMP  AL, 13
    JE   RP_DONE
    CMP  AL, 8
    JE   RP_BS
    CMP  CX, 4
    JAE  RP_L
    MOV  [DI], AL
    INC  DI
    INC  CX
    JMP  RP_L
RP_BS:
    CMP  CX, 0
    JE   RP_L
    DEC  DI
    DEC  CX
    JMP  RP_L
RP_DONE:
    MOV  BYTE PTR [DI], 0
    CALL EmitCRLF
    RET
ReadPin4 ENDP

; ===========================================================
; ReadNum  -  read digit chars from keyboard -> AX
;   Uses shift-add x10 to avoid MUL clobbering DX.
; ===========================================================
ReadNum PROC NEAR
    MOV  DI, OFFSET inAmt
    MOV  CX, 0
RN_L:
    CALL GetChar
    CMP  AL, 13
    JE   RN_DONE
    CMP  AL, 8
    JE   RN_BS
    CMP  CX, 5
    JAE  RN_L
    CMP  AL, '0'
    JB   RN_L
    CMP  AL, '9'
    JA   RN_L
    MOV  [DI], AL
    INC  DI
    INC  CX
    JMP  RN_L
RN_BS:
    CMP  CX, 0
    JE   RN_L
    DEC  DI
    DEC  CX
    JMP  RN_L
RN_DONE:
    MOV  BYTE PTR [DI], 0
    CALL EmitCRLF

    MOV  SI, OFFSET inAmt
    MOV  AX, 0
RN_CONV:
    MOV  BL, [SI]
    CMP  BL, 0
    JE   RN_CEND
    ; AX = AX*10 via shift-add (BX reused as temp)
    MOV  BX, AX
    SHL  AX, 1              ; AX*2
    SHL  BX, 1              ; BX = orig*2
    SHL  BX, 1              ; BX = orig*4
    SHL  BX, 1              ; BX = orig*8
    ADD  AX, BX             ; AX = orig*10
    MOV  BL, [SI]
    MOV  BH, 0
    SUB  BX, '0'
    ADD  AX, BX
    INC  SI
    JMP  RN_CONV
RN_CEND:
    RET
ReadNum ENDP

; ===========================================================
; ParseNum
;   Input : SI = pointer into fBuf at first digit of balance
;   Output: AX = integer value; SI advanced past digits
;   Uses shift-add x10 (no DX clobber).
; ===========================================================
ParseNum PROC NEAR
    MOV  AX, 0
PN_L:
    MOV  BL, fBuf[SI]
    CMP  BL, ','
    JE   PN_DONE
    CMP  BL, 13
    JE   PN_DONE
    CMP  BL, 10
    JE   PN_DONE
    CMP  BL, 0
    JE   PN_DONE
    ; AX = AX*10
    MOV  BX, AX
    SHL  AX, 1
    SHL  BX, 1
    SHL  BX, 1
    SHL  BX, 1
    ADD  AX, BX
    ; add digit
    MOV  BL, fBuf[SI]
    MOV  BH, 0
    SUB  BL, '0'
    ADD  AX, BX
    INC  SI
    JMP  PN_L
PN_DONE:
    RET
ParseNum ENDP

; ===========================================================
; Num2Str
;   Input : AX = non-negative integer
;   Output: nBuf = null-terminated decimal string
; ===========================================================
Num2Str PROC NEAR
    MOV  DI, OFFSET nBuf
    MOV  CX, 7
N2S_CLR:
    MOV  BYTE PTR [DI], 0
    INC  DI
    LOOP N2S_CLR

    CMP  AX, 0
    JNE  N2S_DIV
    MOV  nBuf[0], '0'
    RET

N2S_DIV:
    MOV  CX, 0
N2S_LOOP:
    CMP  AX, 0
    JE   N2S_REV
    MOV  DX, 0
    MOV  BX, 10
    DIV  BX                 ; AX=quotient, DX=remainder
    ADD  DL, '0'
    PUSH DX
    INC  CX
    JMP  N2S_LOOP

N2S_REV:
    MOV  DI, OFFSET nBuf
N2S_POP:
    JCXZ N2S_DONE
    POP  DX
    MOV  [DI], DL
    INC  DI
    DEC  CX
    JMP  N2S_POP
N2S_DONE:
    MOV  BYTE PTR [DI], 0
    RET
Num2Str ENDP

; ===========================================================
; PrintNum  -  print AX as unsigned decimal
; ===========================================================
PrintNum PROC NEAR
    CALL Num2Str
    MOV  SI, OFFSET nBuf
PNU_L:
    MOV  AL, [SI]
    CMP  AL, 0
    JE   PNU_DONE
    MOV  DL, AL
    MOV  AH, 02h
    INT  21h
    INC  SI
    JMP  PNU_L
PNU_DONE:
    RET
PrintNum ENDP

; ===========================================================
; _PrintSI  -  print null-terminated string at DS:SI
; ===========================================================
_PrintSI PROC NEAR
PSI_L:
    MOV  AL, [SI]
    CMP  AL, 0
    JE   PSI_DONE
    MOV  DL, AL
    MOV  AH, 02h
    INT  21h
    INC  SI
    JMP  PSI_L
PSI_DONE:
    RET
_PrintSI ENDP

; ===========================================================
; GetChar  -  read one key with echo, return in AL
; ===========================================================
GetChar PROC NEAR
    MOV  AH, 01h
    INT  21h
    RET
GetChar ENDP

; ===========================================================
; EmitCRLF  -  output CR + LF
; ===========================================================
EmitCRLF PROC NEAR
    MOV  DL, 13
    MOV  AH, 02h
    INT  21h
    MOV  DL, 10
    INT  21h
    RET
EmitCRLF ENDP

END MAIN