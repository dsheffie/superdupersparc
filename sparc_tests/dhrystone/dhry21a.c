/*
 *************************************************************************
 *
 *                   "DHRYSTONE" Benchmark Program
 *                   -----------------------------
 *
 *  Version:    C, Version 2.1
 *
 *  File:       dhry_1.c (part 2 of 3)
 *
 *  Date:       May 25, 1988
 *
 *  Author:     Reinhold P. Weicker
 *
 *************************************************************************
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include "dhry.h"
#include "printf.h"

/* Global Variables: */

Rec_Pointer     Ptr_Glob,
                Next_Ptr_Glob;
int             Int_Glob;
Boolean         Bool_Glob;
char            Ch_1_Glob,
                Ch_2_Glob;
int             Arr_1_Glob [50];
int             Arr_2_Glob [50] [50];

char Reg_Define[] = "Register option selected.";

Enumeration     Func_1 ();
  /* forward declaration necessary since Enumeration may not simply be int */


#ifndef ROPT
#define REG
        /* REG becomes defined as empty */
        /* i.e. no register variables   */
#else
#define REG register
#endif

void Proc_1(REG Rec_Pointer);
void Proc_2 (One_Fifty *);
void Proc_3 (Rec_Pointer *);
void Proc_4 (void);
void Proc_5 (void);
#ifdef  NOSTRUCTASSIGN
 void memcpy (register char *, register char *, register int);
#endif

extern Boolean Func_2 (Str_30, Str_30);
extern void Proc_6 (Enumeration, Enumeration *);
extern void Proc_7 (One_Fifty, One_Fifty, One_Fifty *);
extern void Proc_8 (Arr_1_Dim, Arr_2_Dim, int, int);


/* variables for time measurement: */

#define Too_Small_Time 2
                /* Measurements should last at least 2 seconds */

uint32_t begin_ticks, end_ticks, user_ticks;

double          Begin_Time,
                End_Time,
                User_Time;

double          Microseconds,
                Dhrystones_Per_Second,
                Vax_Mips;

/* end of variables for time measurement */

/* SPARC bare metal (ooo_core / sparc_iss): no timer -- ooo_core reports the
 * cycles and IPC of the whole run */
static inline uint32_t ticks() {
  return 0;
}

static Rec_Type rt0, rt1;

int main (int argc, char *argv[])
{
  One_Fifty       Int_1_Loc;
  REG   One_Fifty       Int_2_Loc = 0;
  One_Fifty       Int_3_Loc;
  REG   char            Ch_Index;
  Enumeration     Enum_Loc;
  Str_30          Str_1_Loc;
  Str_30          Str_2_Loc;
  REG   int             Run_Index;
  REG   int             Number_Of_Runs;


  Next_Ptr_Glob = (Rec_Pointer)&rt0;
  Ptr_Glob = (Rec_Pointer)&rt1;

  
  Ptr_Glob->Ptr_Comp                    = Next_Ptr_Glob;
  Ptr_Glob->Discr                       = Ident_1;
  Ptr_Glob->variant.var_1.Enum_Comp     = Ident_3;
  Ptr_Glob->variant.var_1.Int_Comp      = 40;
  strcpy (Ptr_Glob->variant.var_1.Str_Comp,
	  "DHRYSTONE PROGRAM, SOME STRING");
  strcpy (Str_1_Loc, "DHRYSTONE PROGRAM, 1'ST STRING");

  Arr_2_Glob [8][7] = 10;
  /* Was missing in published program. Without this statement,    */
  /* Arr_2_Glob [8][7] would have an undefined value.             */
  /* Warning: With 16-Bit processors and Number_Of_Runs > 32000,  */
  /* overflow may occur for this array element.                   */

  printf_ ("\n");
  printf_ ("Dhrystone Benchmark, Version 2.1 (Language: C)\n");
  printf_ ("\n");
  /*
    if (Reg)
    {
    printf_ ("Program compiled with 'register' attribute\n");
    printf_ ("\n");
    }
    else
    {
    printf_ ("Program compiled without 'register' attribute\n");
    printf_ ("\n");
    }
  */

  Number_Of_Runs = DHRY_RUNS;
  printf_ ("Execution starts, %d runs through Dhrystone\n",Number_Of_Runs);

  /***************/
  /* Start timer */
  /***************/

  begin_ticks = ticks();

  for (Run_Index = 1; Run_Index <= Number_Of_Runs; ++Run_Index)
    {

      Proc_5();
      Proc_4();
      /* Ch_1_Glob == 'A', Ch_2_Glob == 'B', Bool_Glob == true */
      Int_1_Loc = 2;
      Int_2_Loc = 3;
      strcpy (Str_2_Loc, "DHRYSTONE PROGRAM, 2'ND STRING");
      Enum_Loc = Ident_2;
      Bool_Glob = ! Func_2 (Str_1_Loc, Str_2_Loc);
      /* Bool_Glob == 1 */
      while (Int_1_Loc < Int_2_Loc)  /* loop body executed once */
	{
	  Int_3_Loc = 5 * Int_1_Loc - Int_2_Loc;
	  /* Int_3_Loc == 7 */
	  Proc_7 (Int_1_Loc, Int_2_Loc, &Int_3_Loc);
	  /* Int_3_Loc == 7 */
	  Int_1_Loc += 1;
	} /* while */
      /* Int_1_Loc == 3, Int_2_Loc == 3, Int_3_Loc == 7 */
      Proc_8 (Arr_1_Glob, Arr_2_Glob, Int_1_Loc, Int_3_Loc);
      /* Int_Glob == 5 */
      Proc_1 (Ptr_Glob);
      for (Ch_Index = 'A'; Ch_Index <= Ch_2_Glob; ++Ch_Index)
	/* loop body executed twice */
	{
	  if (Enum_Loc == Func_1 (Ch_Index, 'C'))
	    /* then, not executed */
	    {
	      Proc_6 (Ident_1, &Enum_Loc);
	      strcpy (Str_2_Loc, "DHRYSTONE PROGRAM, 3'RD STRING");
	      Int_2_Loc = Run_Index;
	      Int_Glob = Run_Index;
	    }
	}
      /* Int_1_Loc == 3, Int_2_Loc == 3, Int_3_Loc == 7 */
      Int_2_Loc = Int_2_Loc * Int_1_Loc;
      Int_1_Loc = Int_2_Loc / Int_3_Loc;
      Int_2_Loc = 7 * (Int_2_Loc - Int_3_Loc) - Int_1_Loc;
      /* Int_1_Loc == 1, Int_2_Loc == 13, Int_3_Loc == 7 */
      Proc_2 (&Int_1_Loc);
      /* Int_1_Loc == 5 */

    } /* loop "for Run_Index" */

  /**************/
  /* Stop timer */
  /**************/

  end_ticks = ticks();

  printf_ ("Execution ends\n");
  printf_ ("\n");
  printf_ ("Final values of the variables used in the benchmark:\n");
  printf_ ("\n");
  printf_ ("Int_Glob:            %d\n", Int_Glob);
  printf_ ("        should be:   %d\n", 5);
  printf_ ("Bool_Glob:           %d\n", Bool_Glob);
  printf_ ("        should be:   %d\n", 1);
  printf_ ("Ch_1_Glob:           %c\n", Ch_1_Glob);
  printf_ ("        should be:   %c\n", 'A');
  printf_ ("Ch_2_Glob:           %c\n", Ch_2_Glob);
  printf_ ("        should be:   %c\n", 'B');
  printf_ ("Arr_1_Glob[8]:       %d\n", Arr_1_Glob[8]);
  printf_ ("        should be:   %d\n", 7);
  printf_ ("Arr_2_Glob[8][7]:    %d\n", Arr_2_Glob[8][7]);
  printf_ ("        should be:   Number_Of_Runs + 10\n");
  printf_ ("Ptr_Glob->\n");
  printf_ ("  Ptr_Comp:          %d\n", (int) Ptr_Glob->Ptr_Comp);
  printf_ ("        should be:   (implementation-dependent)\n");
  printf_ ("  Discr:             %d\n", Ptr_Glob->Discr);
  printf_ ("        should be:   %d\n", 0);
  printf_ ("  Enum_Comp:         %d\n", Ptr_Glob->variant.var_1.Enum_Comp);
  printf_ ("        should be:   %d\n", 2);
  printf_ ("  Int_Comp:          %d\n", Ptr_Glob->variant.var_1.Int_Comp);
  printf_ ("        should be:   %d\n", 17);
  printf_ ("  Str_Comp:          %s\n", Ptr_Glob->variant.var_1.Str_Comp);
  printf_ ("        should be:   DHRYSTONE PROGRAM, SOME STRING\n");
  printf_ ("Next_Ptr_Glob->\n");
  printf_ ("  Ptr_Comp:          %d\n", (int) Next_Ptr_Glob->Ptr_Comp);
  printf_ ("        should be:   (implementation-dependent), same as above\n");
  printf_ ("  Discr:             %d\n", Next_Ptr_Glob->Discr);
  printf_ ("        should be:   %d\n", 0);
  printf_ ("  Enum_Comp:         %d\n", Next_Ptr_Glob->variant.var_1.Enum_Comp);
  printf_ ("        should be:   %d\n", 1);
  printf_ ("  Int_Comp:          %d\n", Next_Ptr_Glob->variant.var_1.Int_Comp);
  printf_ ("        should be:   %d\n", 18);
  printf_ ("  Str_Comp:          %s\n", Next_Ptr_Glob->variant.var_1.Str_Comp);
  printf_ ("        should be:   DHRYSTONE PROGRAM, SOME STRING\n");
  printf_ ("Int_1_Loc:           %d\n", Int_1_Loc);
  printf_ ("        should be:   %d\n", 5);
  printf_ ("Int_2_Loc:           %d\n", Int_2_Loc);
  printf_ ("        should be:   %d\n", 13);
  printf_ ("Int_3_Loc:           %d\n", Int_3_Loc);
  printf_ ("        should be:   %d\n", 7);
  printf_ ("Enum_Loc:            %d\n", Enum_Loc);
  printf_ ("        should be:   %d\n", 1);
  printf_ ("Str_1_Loc:           %s\n", Str_1_Loc);
  printf_ ("        should be:   DHRYSTONE PROGRAM, 1'ST STRING\n");
  printf_ ("Str_2_Loc:           %s\n", Str_2_Loc);
  printf_ ("        should be:   DHRYSTONE PROGRAM, 2'ND STRING\n");
  printf_ ("\n");

  user_ticks = end_ticks - begin_ticks;
  printf_("%u ticks\n", user_ticks);

  {
      Microseconds = User_Time * Mic_secs_Per_Second
	/ (double) Number_Of_Runs;
      Dhrystones_Per_Second = (double) Number_Of_Runs / User_Time;
      Vax_Mips = Dhrystones_Per_Second / 1757.0;

#ifdef ROPT
      printf_ ("Register option selected?  YES\n");
#else
      printf_ ("Register option selected?  NO\n");
      strcpy(Reg_Define, "Register option not selected.");
#endif
      printf_ ("Microseconds for one run through Dhrystone: ");
      printf_ ("%7.1f \n", Microseconds);
      printf_ ("Dhrystones per Second:                      ");
      printf_ ("%10.1f \n", Dhrystones_Per_Second);
      printf_ ("VAX MIPS rating = %10.3f \n",Vax_Mips);
      printf_ ("\n");

    }
  //free(Next_Ptr_Glob);
  //free(Ptr_Glob);
  /* the result (%g6 after _start): 0x600d if every final value is the one
   * Dhrystone 2.1 documents, else a bit per wrong one */
  {
    int bad = 0;
    bad |= (Int_Glob != 5) << 0;
    bad |= (Bool_Glob != 1) << 1;
    bad |= (Ch_1_Glob != 'A') << 2;
    bad |= (Ch_2_Glob != 'B') << 3;
    bad |= (Arr_1_Glob[8] != 7) << 4;
    bad |= (Arr_2_Glob[8][7] != Number_Of_Runs + 10) << 5;
    bad |= (Ptr_Glob->Discr != 0) << 6;
    bad |= (Ptr_Glob->variant.var_1.Enum_Comp != 2) << 7;
    bad |= (Ptr_Glob->variant.var_1.Int_Comp != 17) << 8;
    bad |= (strcmp(Ptr_Glob->variant.var_1.Str_Comp, "DHRYSTONE PROGRAM, SOME STRING") != 0) << 9;
    bad |= (Next_Ptr_Glob->variant.var_1.Int_Comp != 18) << 10;
    bad |= (Int_1_Loc != 5) << 11;
    bad |= (Int_2_Loc != 13) << 12;
    bad |= (Int_3_Loc != 7) << 13;
    bad |= (Enum_Loc != 1) << 14;
    bad |= (strcmp(Str_1_Loc, "DHRYSTONE PROGRAM, 1'ST STRING") != 0) << 15;
    bad |= (strcmp(Str_2_Loc, "DHRYSTONE PROGRAM, 2'ND STRING") != 0) << 16;
    return bad ? bad : 0x600d;
  }
  
  return 0;
}


void
Proc_1 (REG Rec_Pointer Ptr_Val_Par)
    /* executed once */
{
  REG Rec_Pointer Next_Record = Ptr_Val_Par->Ptr_Comp;
                                        /* == Ptr_Glob_Next */
  /* Local variable, initialized with Ptr_Val_Par->Ptr_Comp,    */
  /* corresponds to "rename" in Ada, "with" in Pascal           */

  structassign (*Ptr_Val_Par->Ptr_Comp, *Ptr_Glob);
  Ptr_Val_Par->variant.var_1.Int_Comp = 5;
  Next_Record->variant.var_1.Int_Comp
        = Ptr_Val_Par->variant.var_1.Int_Comp;
  Next_Record->Ptr_Comp = Ptr_Val_Par->Ptr_Comp;
  Proc_3 (&Next_Record->Ptr_Comp);
    /* Ptr_Val_Par->Ptr_Comp->Ptr_Comp
                        == Ptr_Glob->Ptr_Comp */
  if (Next_Record->Discr == Ident_1)
    /* then, executed */
  {
    Next_Record->variant.var_1.Int_Comp = 6;
    Proc_6 (Ptr_Val_Par->variant.var_1.Enum_Comp,
           &Next_Record->variant.var_1.Enum_Comp);
    Next_Record->Ptr_Comp = Ptr_Glob->Ptr_Comp;
    Proc_7 (Next_Record->variant.var_1.Int_Comp, 10,
           &Next_Record->variant.var_1.Int_Comp);
  }
  else /* not executed */
    structassign (*Ptr_Val_Par, *Ptr_Val_Par->Ptr_Comp);
} /* Proc_1 */


void
Proc_2 (One_Fifty *Int_Par_Ref)
/******************/
    /* executed once */
    /* *Int_Par_Ref == 1, becomes 4 */
{
  One_Fifty  Int_Loc;
  Enumeration   Enum_Loc = Ident_1;

  Int_Loc = *Int_Par_Ref + 10;
  do /* executed once */
    if (Ch_1_Glob == 'A')
      /* then, executed */
    {
      Int_Loc -= 1;
      *Int_Par_Ref = Int_Loc - Int_Glob;
      Enum_Loc = Ident_1;
    } /* if */
  while (Enum_Loc != Ident_1); /* true */
} /* Proc_2 */


void
Proc_3 (Rec_Pointer *Ptr_Ref_Par)
/******************/
    /* executed once */
    /* Ptr_Ref_Par becomes Ptr_Glob */
{
  if (Ptr_Glob != Null)
    /* then, executed */
    *Ptr_Ref_Par = Ptr_Glob->Ptr_Comp;
  Proc_7 (10, Int_Glob, &Ptr_Glob->variant.var_1.Int_Comp);
} /* Proc_3 */


void
Proc_4 (void) /* without parameters */
/*******/
    /* executed once */
{
  Boolean Bool_Loc;

  Bool_Loc = Ch_1_Glob == 'A';
  Bool_Glob = Bool_Loc | Bool_Glob;
  Ch_2_Glob = 'B';
} /* Proc_4 */


void
Proc_5 (void) 	/* without parameters */
		/* executed once */
{
  Ch_1_Glob = 'A';
  Bool_Glob = false;
} /* Proc_5 */


        /* Procedure for the assignment of structures,          */
        /* if the C compiler doesn't support this feature       */
#ifdef  NOSTRUCTASSIGN
void
memcpy (register char *d, register char *s, register int l)
/* register char   *d; register char   *s; register int    l; */
{
        while (l--) *d++ = *s++;
}
#endif
