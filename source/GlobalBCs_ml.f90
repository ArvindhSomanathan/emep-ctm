! <GlobalBCs_ml.f90 - A component of the EMEP MSC-W Unified Eulerian
!          Chemical transport Model>
!*****************************************************************************!
!*
!*  Copyright (C) 2007-201409 met.no
!*
!*  Contact information:
!*  Norwegian Meteorological Institute
!*  Box 43 Blindern
!*  0313 OSLO
!*  NORWAY
!*  email: emep.mscw@met.no
!*  http://www.emep.int
!*
!*    This program is free software: you can redistribute it and/or modify
!*    it under the terms of the GNU General Public License as published by
!*    the Free Software Foundation, either version 3 of the License, or
!*    (at your option) any later version.
!*
!*    This program is distributed in the hope that it will be useful,
!*    but WITHOUT ANY WARRANTY; without even the implied warranty of
!*    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
!*    GNU General Public License for more details.
!*
!*    You should have received a copy of the GNU General Public License
!*    along with this program.  If not, see <http://www.gnu.org/licenses/>.
!*****************************************************************************!
module GlobalBCs_ml
! -----------------------------------------------------------------------
! DATA/SUBROUTINES FOR USING Logan climatology for BOUNDARY CONDITIONS (BCs)
! Time-of-year, height, and latitude functions applied to non-oozne BCs
!
! Known issues:
!   Seasonal variation is often weaker at higher altitude.
!   The "vmin" minimum concentration can correct for some of this.
!   It is after all (we hope) the near-surface BCs which matter most.
!   In principle one could specify al concentrations as complex 3-D fields
!   here, but that would need a new setup routine
!
! -----------------------------------------------------------------------

use CheckStop_ml,   only: CheckStop
use GridValues_ml,  only: glat_fdom, GlobalPosition
use Functions_ml,   only: StandardAtmos_kPa_2_km ! for use in Hz scaling
use GridValues_ml,  only: lb2ij, AN, glat_fdom, glon_fdom,A_mid, B_mid
use Io_ml,          only: IO_GLOBBC, ios, open_file, PrintLog
use ModelConstants_ml, only: PPB, KMAX_MID, Pref, MasterProc, DO_SAHARA, &
                             USES, DEBUG, & !%GLOBBC, &
                          iyr_trend, IIFULLDOM, JJFULLDOM
use NetCDF_ml,      only: GetCDF, Read_Inter_CDF
use Par_ml,         only: GIMAX, GJMAX, IRUNBEG, JRUNBEG
use PhysicalConstants_ml, only: PI
use TimeDate_ml,    only: daynumber
use TimeDate_ExtraUtil_ml,only: date2string

implicit none
private
  !/-- subroutines

public :: GetGlobalData         ! Opens, reads bc_data, closes global data
public :: setgl_actarray

logical, parameter, private :: &
!  DEBUG_GLOBBC = .false., &
  DEBUG_Logan  = .false., &
  DEBUG_HZ     = .false.

! A. Define parameters and indices of global-model species
! -----------------------------------------------------------------------
!-- definitions in Jostein's grid. Generally, these will be from
!   a Txx model, where xx is currently 21.
!integer, parameter, public  :: & ! Assume BC defined in large domain:
!  IGLOB = IIFULLDOM, &  ! number of large domain grids cells, longitude
!  JGLOB = JJFULLDOM     ! number of large domain grids cells, latitude

! Chemical species:
! -- IBC indices text generated by perl script mkp.jost 
! ** usually only changed when global-model output changes **
integer, public, parameter :: &
   IBC_O3       =  1   &
  ,IBC_NO       =  2   &
  ,IBC_NO2      =  3   &
  ,IBC_PAN      =  4   &
  ,IBC_HNO3     =  5   &  ! used for nitrate too
  ,IBC_SO2      =  6   &
  ,IBC_SO4      =  7   &
  ,IBC_CO       =  8   &
  ,IBC_C2H6     =  9   &
  ,IBC_C4H10    = 10   &
  ,IBC_HCHO     = 11   &
  ,IBC_CH3CHO   = 12   &
  ,IBC_H2O2     = 13   &
  ,IBC_NH4_f    = 14   &
  ,IBC_NO3_f    = 15   &
  ,IBC_NO3_c    = 16   &
  ,IBC_SEASALT_f= 17   &
  ,IBC_SEASALT_c= 18   &
  ,IBC_SEASALT_g= 19   &
  ,IBC_DUST_f   = 20   &      ! Dust
  ,IBC_DUST_c   = 21   &      ! Dust
  ,NGLOB_BC     = IBC_DUST_c  ! Totan no. species setup in this module


! we define some concentrations in terms of sine curves and other simple data:
type, private :: sineconc
  real :: surf       ! Mean surface conc. (ppb)
  integer :: dmax    ! Day when concentrations peak
  real :: amp        ! amplitude of surface conc. (ppb)
  real :: hz         ! Scale-height (km) - height to drop 1/e concentration
  real :: vmin       ! background, minimum conc., in vertical direction
  real :: hmin       ! background, minimum conc., in horiz direction
  real :: conv_fac   ! factor to convert input data to mixing ratio
end type sineconc
type(sineconc), private, save, dimension(NGLOB_BC) :: SpecBC

type, private :: SIAfac ! trends in boundary conditions
  integer :: year
  real:: so2,nox,nh4
end type SIAfac

! the actual values - do not use IGLOB,JGLOB, but the actual one's
integer, save, private  :: iglbeg, iglend, jglbeg, jglend
! -----------------------------------------------------------------------
integer,parameter ::KMAX20=20
!temporary used by BoundaryConditions
real,public :: O3fix=0.0
real,public :: trend_o3=1.0, trend_co, trend_voc

contains

subroutine setgl_actarray(iglobact,jglobact)
! -----------------------------------------------------------------------
! set actual domain in model coord
! -----------------------------------------------------------------------
  integer,intent(out)   :: iglobact,jglobact
  real :: hel1,hel2

  hel1 = IRUNBEG
  hel2 = IRUNBEG+GIMAX-1
  iglbeg = nint(hel1)  ! global i coord of start of model domain
  iglend = nint(hel2)
  iglobact = GIMAX

  hel1 = JRUNBEG
  hel2 = JRUNBEG+GJMAX-1
  jglbeg = nint(hel1)  ! global j coord of start of model domain
  jglend = nint(hel2)
  jglobact = GJMAX
 end subroutine setgl_actarray

subroutine GetGlobalData(year,month,ibc,used,        &
                         iglobact,jglobact,bc_data,io_num,errcode)
! -----------------------------------------------------------------------
! HANDLES READ_IN OF GLOBAL DATA. We read in the raw data from the
! global model, and do the vertical interpolation to EMEP k values
! here if the species is to be used.
! -----------------------------------------------------------------------
  integer,             intent(in) :: year       ! for Mace Head correction
  integer,             intent(in) :: month
  integer,             intent(in) :: ibc        ! Index of BC
  integer,             intent(in) :: used       ! set to 1 if species wanted
  integer,             intent(in) :: iglobact,jglobact
  real, dimension(iglobact,jglobact,KMAX_MID), &
                      intent(out) :: bc_data   ! Data from Logan model
  integer,            intent(out) :: io_num    ! i/o number
  integer,          intent(inout) :: errcode   ! i/o number

  logical, save :: first_call = .true.
  real, dimension(IIFULLDOM,JJFULLDOM,KMAX_MID) :: bc_rawdata   ! Data (was rtcdmp)

  integer, allocatable,dimension(:,:), save :: lat5     ! for latfunc below
  real, dimension(NGLOB_BC,6:14), save  :: latfunc  ! lat. function
  real, save ::  twopi_yr, cosfac                   ! for time-variations
  !---------------------------------------------------------------------------
  ! Mace Head ozone concentrations for backgroudn sectors
  ! from Fig 5.,  Derwent et al., 1998, AE Vol. 32, No. 2, pp 145-157
  real, dimension(12,1990:2011), parameter :: macehead_year=reshape(&
   [35.3,36.3,38.4,43.0,41.2,33.4,35.1,27.8,33.7,36.2,28.4,37.7,& !1990
    36.1,38.7,37.7,45.8,38.8,36.3,29.6,33.1,33.4,35.7,37.3,36.7,& !1991
    36.1,37.3,41.8,39.6,41.2,31.5,28.3,30.3,31.3,34.2,36.1,34.9,& !1992
    37.6,40.4,44.4,42.6,43.4,29.2,28.5,29.6,32.2,37.3,37.3,38.3,& !1993
    38.6,37.3,45.7,43.8,42.9,35.1,30.8,30.5,33.8,36.5,34.0,37.3,& !1994
    37.5,37.1,41.6,42.4,41.1,33.1,29.1,28.7,33.7,34.8,35.0,36.0,& !1995
    37.0,40.1,42.9,44.6,41.3,38.3,29.3,29.4,35.6,38.4,37.8,38.4,& !1996
    36.2,41.9,41.8,40.4,40.6,34.4,26.2,29.3,31.3,35.2,25.7,39.5,& !1997
    38.6,42.0,44.6,45.1,44.2,33.0,29.7,32.9,35.7,38.8,39.7,40.4,& !1998
    39.9,44.5,49.4,45.0,42.8,34.3,29.0,30.0,31.8,36.9,39.6,39.2,& !1999
    39.5,42.1,41.8,43.8,43.4,34.5,28.0,27.3,33.6,37.4,35.6,35.8,& !2000
    37.3,38.0,42.2,44.8,42.6,34.9,28.9,29.4,29.9,35.3,37.3,37.5,& !2001
  ! Preliminary BCs generated using Mace Head CFC and other greenhouse gases
  ! data to define clean air masses. Data cover all of 2002 and 9 months
  ! of 2003. What to do for Oct-Dec 2003?
  ! Could use (1) 2002 data or (2) 10-year average?
  ! Simmonds paper would support (1), simplicity (2).
  ! After seeing earlier 2003 plots, chose (2).
    42.4,44.4,45.5,45.0,45.9,39.8,32.5,28.7,37.7,39.3,40.5,42.3,& !2002
    39.8,40.1,44.7,45.4,45.7,41.7,33.3,31.0,35.7,37.9,40.9,38.1,& !2003
    40.8,42.0,48.3,46.6,39.9,31.9,32.4,32.1,33.9,36.7,40.2,39.8,& !2004
    40.9,41.4,44.1,45.6,42.7,32.9,26.7,30.0,33.2,37.7,39.5,38.0,& !2005
  ! 2006 and 2007 are calculated with using IE31 O3 data and
  ! trajectory sectors (based on PARLAM-PS and HIRLAM20 met) for resp. year
    39.8,42.4,44.2,48.3,41.3,39.0,31.9,29.5,34.8,37.4,41.9,39.9,& !2006
    40.7,38.2,46.1,46.4,40.9,34.5,31.2,28.8,33.3,36.1,40.6,41.7,& !2007
  ! 2008 Mace Head correction calculated using IE31 O3 data and
  ! trajectory sectors (based on HIRLAM20 met) for 2008
    41.0,45.1,48.0,46.3,44.2,37.1,30.8,31.3,34.3,37.5,37.9,40.0,& !2008
  ! 2009 to 2011 Mace Head correction calculated using IE31 O3 data and
  ! trajectory sectors (based on ECMWF met) for respective year
    37.7,43.3,46.5,46.2,41.6,39.1,31.0,29.0,34.5,34.4,40.5,38.4,& !2009
    36.8,38.9,43.9,46.4,41.7,35.5,31.0,31.3,35.6,36.7,33.4,33.8,& !2010
    36.5,42.4,43.3,44.5,40.2,34.6,30.1,30.8,32.0,34.7,37.7,38.1]& !2011
    ,[12,1-1990+2011])
  real, dimension(12), parameter :: macehead_default=&
  ! Defaults from 1998-2010 average
    (/39.8,41.9,45.4,46.5,43.2,36.2,30.5,30.1,34.1,37.0,39.0,38.5/)
  real, dimension(12):: macehead_O3=macehead_default
  !---------------------------------------------------------------------------
  integer :: i, j, k, i0, i1, j1, icount
  real    :: f0, f1             ! interpolation factors
  character(len=30) :: fname    ! input filename
  character(len=99) :: txtmsg   ! error messages
  character(len=30) :: BCpoll   ! pollutant name
  real,allocatable,save, dimension(:) :: p_kPa, h_km  !Use of standard atmosphere

  real :: scale_old, scale_new,iMH,jMH
  logical :: notfound !set true if NetCDF BIC are not found
  real, parameter :: macehead_lat = 53.3 !latitude of Macehead station
  real, parameter :: macehead_lon = -9.9 !longitude of Macehead station


!----------------------------------------------------------
!Trends 1980-2003 derived from EPA emissions of so2,nox.
! nh4 derived from 2/3so3+1/3nox
!Support for SO2 can be found in Hicks, Artz, Meyer and Hosker, 2002
! Figure 7 (Eastern US) which show 'close' correspondance between national
! emissions and concentration trend

!1920-1970 BCs derived from:
!  NH4: nh3 emissions
!  SOx: winter ice cores, Col du dome
!  NOx: winter ice cores
!1890-1920: trends from emissions for SOx,NOx,NH3, Aardenne USA
! Updated: April 2013
! - use data above to 1980, then EPA download of April 2013
! - then IIASA/ECLAIRE/ECLIPSE
 type(SIAfac), dimension(37), save :: SIAtrends = (/ &
    SIAfac(1890,0.12,0.15,0.44) &
   ,SIAfac(1900,0.18,0.20,0.48) &
   ,SIAfac(1910,0.27,0.27,0.52) &
   ,SIAfac(1920,0.32,0.33,0.59) &
   ,SIAfac(1930,0.35,0.33,0.55) &
   ,SIAfac(1940,0.46,0.25,0.59) &
   ,SIAfac(1950,0.59,0.33,0.69) &
   ,SIAfac(1960,0.76,0.50,0.76) &
   ,SIAfac(1970,0.95,0.75,0.90) &
   ,SIAfac(1980,   1.000,   1.000,   1.000)&
   ,SIAfac(1985,   0.899,   0.951,   0.989)&
   ,SIAfac(1990,   0.890,   0.943,   0.920)&
   ,SIAfac(1991,   0.863,   0.930,   0.934)&
   ,SIAfac(1992,   0.852,   0.933,   0.947)&
   ,SIAfac(1993,   0.840,   0.936,   0.963)&
   ,SIAfac(1994,   0.823,   0.936,   0.978)&
   ,SIAfac(1995,   0.718,   0.922,   0.993)&
   ,SIAfac(1996,   0.709,   0.915,   1.007)&
   ,SIAfac(1997,   0.727,   0.912,   1.027)&
   ,SIAfac(1998,   0.731,   0.899,   1.052)&
   ,SIAfac(1999,   0.677,   0.844,   1.035)&
   ,SIAfac(2000,   0.631,   0.835,   1.046)&
   ,SIAfac(2001,   0.615,   0.796,   0.786)&
   ,SIAfac(2002,   0.570,   0.781,   0.880)&
   ,SIAfac(2003,   0.568,   0.753,   0.877)&
   ,SIAfac(2004,   0.565,   0.726,   0.874)&
   ,SIAfac(2005,   0.572,   0.703,   0.870)&
   ,SIAfac(2006,   0.514,   0.681,   0.885)&
   ,SIAfac(2007,   0.456,   0.658,   0.900)&
   ,SIAfac(2008,   0.399,   0.635,   0.930)&
   ,SIAfac(2009,   0.320,   0.579,   0.928)&
   ,SIAfac(2010,   0.292,   0.543,   0.925)&
   ,SIAfac(2011,   0.265,   0.488,   0.921)&
   ,SIAfac(2012,   0.213,   0.421,   0.917)&
   ! Default here from IIASA ECLAIRE/ECLIPSE
   ! related to 2005 emissions as base
   ! (Created by mk.UStrends, April 2013)
   ,SIAfac(2030,   0.155,   0.252,   0.953)&
   ,SIAfac(2050,   0.225,   0.276,   0.977)&! Last year which works
   ,SIAfac(2200,   0.225,   0.276,   0.977)&! FAKE for interp
 /)
  type(SIAfac), save :: SIAtrend

  if (iyr_trend < SIAtrends(1)%year .or. iyr_trend >= SIAtrends(37)%year ) then
    write(unit=txtmsg,fmt=*) "Unspecified trend BCs for this year:", ibc, year
    call CheckStop(txtmsg)
  end if

!================================================================== 
! Interpolate between boundary condition years if needed
  i0 = 1
  do i = 1, size(SIAtrends(:)%year) 
    if ( iyr_trend >= SIAtrends(i)%year ) i0 = i
    !if(MasterProc) print "(a,5i6)", "USAsrch: ", i, i0, BCtrend(i)%year, BCtrend(i0)%year
  end do

  i1= i0 + 1
  f0 =     (SIAtrends(i1)%year - iyr_trend)/&
       real(SIAtrends(i1)%year - SIAtrends(i0)%year )
  f1 =     (iyr_trend        - SIAtrends(i0)%year )/&
       real(SIAtrends(i1)%year - SIAtrends(i0)%year )

  SIAtrend%so2 =f0*SIAtrends(i0)%so2 + f1*SIAtrends(i1)%so2
  SIAtrend%nox =f0*SIAtrends(i0)%nox + f1*SIAtrends(i1)%nox
  SIAtrend%nh4 =f0*SIAtrends(i0)%nh4 + f1*SIAtrends(i1)%nh4

!  if (MasterProc.and.first_call) then
!     write(unit=txtmsg,fmt="(a,2i5,3f8.3)") &
!       "BC:trends SOx,NOx,NH3 ", iyr_trend, SIAtrend
!     call PrintLog(txtmsg)
!  end if

!================================================================== 
! Trends - derived from EMEP report 3/97
! adjustment for years outside the range 1990-2000.

!June 2013 svn 2619:
! Assume O3 increases to 2000, consistent with obs.
! Keep the 1990 base-year for CO and VOC.
  select case(iyr_trend)
  case(2000:)
    trend_o3 = 1.0
    trend_co = 1.0
    trend_voc= 1.0
  case(1990:1999)
    trend_o3 = exp(-0.01*1.0 *(2000-iyr_trend))
    trend_co = 1.0
    trend_voc= 1.0
  case default
    trend_o3 = exp(-0.01*1.0 *(2000-iyr_trend))
    trend_co = exp(-0.01*0.85*(1990-iyr_trend)) ! Zander:CO
    trend_voc= exp(-0.01*0.85*(1990-iyr_trend)) ! Zander,1975-1990
  endselect
  if (MasterProc.and.first_call) then
    write(unit=txtmsg,fmt="(a,i5,3f8.3,3f9.4)") "BC:trends O3,CO,VOC,SOx,NOx,NH3: ", &
       iyr_trend, trend_o3, trend_co, trend_voc, SIAtrend%so2, SIAtrend%nox, SIAtrend%nh4
    call PrintLog(txtmsg)
  endif

!----------------------------------------------------------

  io_num = IO_GLOBBC          ! for closure in BoundCOnditions_ml

!==================================================================
!=========== BCs Generated from Mace Head Data ====================
!
! Here we use the meteorology year to get a reaslistic O3.
!      Later we use iyr_trend to adjust for other years, say for 2050.
! For 2020 "trend" runs  - use 13 yr average as base-O3 (macehead_default)
! then later scale by trend_o3:
  if((iyr_trend==year).and.(year>=1990).and.(year<=2011))then
    macehead_O3=macehead_year(:,year)
  else
    macehead_O3=macehead_default
  endif
!=========== Generated from Mace Head Data =======================

  errcode = 0
  txtmsg = "ok"
  if (DEBUG_Logan) print *,"DEBUG_LOgan ibc, mm", ibc, month

! ========= first call =========================================
  if ( first_call ) then
    ! Set up arrays to contain Logan's grid as lat/long
    !/ COnversions derived from emeplat2Logan etc.:
     allocate(lat5(IIFULLDOM,JJFULLDOM))
     allocate(p_kPa(KMAX_MID), h_km(KMAX_MID))
    twopi_yr = 2.0 * PI / 365.25

    call GlobalPosition  !get glat for global domaib
    forall(i=1:IIFULLDOM,j=1:JJFULLDOM) ! Don't bother with south pole complications
      lat5(i,j) = glat_fdom(i,j)/5   ! lat/5 used in latfunc below
      lat5(i,j) = max(lat5(i,j),6)   ! Min value in latfunc
      lat5(i,j) = min(lat5(i,j),14)  ! Max value in latfunc
    endforall
    ! Define concs where a simple  specification based on lat/mm
    ! etc. will be given
    !                           surf   dmax   amp   hz    vmin  hmin conv_fac!ref
    !                            ppb          ppb   km   hmin,vmin:same units as input data=conv_fac
    SpecBC(IBC_SO2  )  = sineconc( 0.15 , 15.0, 0.05, 999.9, 0.03, 0.03,PPB)!W99, bcKz vmin
    SpecBC(IBC_SO4  )  = sineconc( 0.15 ,180.0, 0.00, 1.6  , 0.05, 0.03,PPB)!W99
    SpecBC(IBC_NO   )  = sineconc( 0.1  , 15.0, 0.03, 4.0  , 0.03, 0.02,PPB)
    SpecBC(IBC_NO2  )  = sineconc( 0.1  , 15.0, 0.03, 4.0  , 0.05, 0.04,PPB)
    SpecBC(IBC_PAN  )  = sineconc( 0.20 ,120.0, 0.15, 999.9, 0.20, 0.1 ,PPB)!Kz change vmin
    SpecBC(IBC_CO   )  = sineconc( 125.0, 75.0, 35.0, 25.0 , 70.0, 30.0,PPB)!JEJ-W
!st 14.05.2014    SpecBC(IBC_SEASALT_F)=sineconc( 0.5  , 15.0,  0.3,  1.6 , 0.01, 0.01,PPB)
!st 14.05.2014    SpecBC(IBC_SEASALT_C)=sineconc( 3.0  , 15.0,  1.0,  1.6 , 0.01, 0.01,PPB)
    SpecBC(IBC_SEASALT_F)=sineconc( 0.2  , 15.0,  0.05,  1.6 , 0.01, 0.01,PPB)
    SpecBC(IBC_SEASALT_C)=sineconc( 1.5  , 15.0,  0.25,  1.6 , 0.01, 0.01,PPB)
    SpecBC(IBC_SEASALT_G)=sineconc( 1.0  , 15.0,  0.5,  1.0 , 0.01, 0.01,PPB)
    SpecBC(IBC_C2H6 )  = sineconc( 2.0  , 75.0, 1.0 , 10.0 , 0.05, 0.05,PPB)
    SpecBC(IBC_C4H10)  = sineconc( 2.0  , 45.0, 1.0 , 6.0  , 0.05, 0.05,PPB)
    SpecBC(IBC_HCHO )  = sineconc( 0.7  ,180.0, 0.3 , 6.0  , 0.05, 0.05,PPB)
    SpecBC(IBC_CH3CHO) = sineconc( 0.3  ,180.0, 0.05 , 6.0  , 0.005, 0.005,PPB) !NAMBLEX,Solberg,etc.
    SpecBC(IBC_HNO3 )  = sineconc( 0.07 ,180.0, 0.03, 999.9,0.025, 0.03,PPB)
                         !~=NO3, but with opposite seasonal var.
    SpecBC(IBC_NO3_f ) = sineconc( 0.07 , 15.0, 0.03, 1.6  ,0.025, 0.02,PPB) !ACE-2
    SpecBC(IBC_NO3_c ) = sineconc( 0.07 , 15.0, 0.00, 1.6  ,0.025, 0.02,PPB) !ACE-2
    SpecBC(IBC_NH4_f ) = sineconc( 0.15 ,180.0, 0.00, 1.6  , 0.05, 0.03,PPB) !ACE-2(SO4/NH4=1)
 ! all BCs read in are in mix. ratio, thus hmin,vmin needs to be in mix. ratio for thosetio for those
    SpecBC(IBC_O3   )  = sineconc(-99.9 ,-99.9,-99.9,-99.9 ,-99.9,10.0*PPB  ,1.)!N1
    SpecBC(IBC_H2O2 )  = sineconc(-99.9 ,-99.9,-99.9,-99.9 ,-99.9,0.01*PPB  ,1.)
  ! Dust: the factor PPB converts from PPB to mixing ratio.
    SpecBC(IBC_DUST_c)=sineconc(-99.9 ,-99.9,-99.9,-99.9 ,-99.9,1.0e-15,1.0)
    SpecBC(IBC_DUST_f)=sineconc(-99.9 ,-99.9,-99.9,-99.9 ,-99.9,1.0e-15,1.0)
    !refs:
    ! N1 - for ozone we read Logan's data, so the only paramater specified
    !      is a min value of 10 ppb. I hope this doesn't come into effect in
    !      Europe as presumably any such min values are in the S. hemisphere.
    !      Still, giving O3 such a value let's us use the same code for
    !      all species.
    ! W99: Warneck, Chemistry of the Natural Atmosphere, 2nd edition, 1999
    !    Academic Press. Fig 10-6 for SO2, SO4.
    ! JEJ - Joffen's suggestions from Mace/Head, UiO and other data..
    !      with scale height estimated large from W99, Isaksen+Hov (1987)
    ! M -Mozart-obs comparison
    ! ACE-2 Lots of conflicting measurements exist, from NH4/SO4=2 to NH4/SO4=0.5
    ! A 'mean' value of NH4/SO4=1 is therefore selected. Otherwise NH4 is assumed to
    ! act as SO4
    ! aNO3 is assumed to act as SO4, but with 1/2 concentrations and seasonal var.
    ! pNO3 is assumed to act like seasalt, with decreasing conc with height, with
    ! approx same conc. as fine nitrate.
    ! The seasonal var of HNO3 is now assumed to be opposite of aNO3.

    ! Consistency check:
    if (DEBUG%GLOBBC) print *, "SPECBC NGLB ",NGLOB_BC
    do i = 1, NGLOB_BC
      if (DEBUG%GLOBBC) print *,"SPECBC i, hmin ",i,SpecBC(i)%surf,SpecBC(i)%hmin
      if( SpecBC(i)%hmin*SpecBC(i)%conv_fac < 1.0e-17) then
        write(unit=txtmsg,fmt="(A,I0)") "PECBC: Error: No SpecBC set for species ", i
        call CheckStop(txtmsg)
      endif
    enddo

    ! Latitude functions taken from Lagrangian model, see Simpson (1992)
    latfunc(:,6:14) = 1.0    ! default
                              !  30        40        50       60         70 degN
    latfunc(IBC_SO2 ,6:14) = (/ 0.05,0.15,0.3 ,0.8 ,1.0 ,0.6 ,0.2 ,0.12,0.05/)
    latfunc(IBC_HNO3,6:14) = (/ 1.00,1.00,1.00,0.85,0.7 ,0.55,0.4 ,0.3 ,0.2 /)
    latfunc(IBC_PAN ,6:14) = (/ 0.15,0.33,0.5 ,0.8 ,1.0 ,0.75,0.5 ,0.3 ,0.1 /)
    latfunc(IBC_CO  ,6:14) = (/ 0.6 ,0.7 ,0.8 ,0.9 ,1.0 ,1.0 ,0.95,0.85,0.8 /)

    latfunc(IBC_SO4   ,:) = latfunc(IBC_SO2 ,:)
    latfunc(IBC_NO    ,:) = latfunc(IBC_SO2 ,:)
    latfunc(IBC_NO2   ,:) = latfunc(IBC_SO2 ,:)
    latfunc(IBC_HCHO  ,:) = latfunc(IBC_HNO3,:)
    latfunc(IBC_CH3CHO,:) = latfunc(IBC_HNO3,:)
    latfunc(IBC_NH4_f ,:) = latfunc(IBC_SO2 ,:)
    latfunc(IBC_NO3_f ,:) = latfunc(IBC_SO2 ,:)
    latfunc(IBC_NO3_c ,:) = latfunc(IBC_SO2 ,:)

    ! Use Standard Atmosphere to get average heights of layers
    p_kPa(:) = 0.001*( A_mid(:) + B_mid(:)*Pref ) ! Pressure in kPa
    h_km = StandardAtmos_kPa_2_km(p_kPa)

    first_call = .false.
  endif ! first_call
! ========= end of first call ===================================
!+
!  Specifies concentrations for a fake set of Logan data.

  fname = "none"           ! dummy for printout
  select case (ibc)
  case (IBC_O3)
    fname=date2string("D3_O3.MM",month=month)
    BCpoll='D3_O3_Logan'
    call ReadBC_CDF(BCpoll,month,bc_rawdata(:,:,KMAX_MID-KMAX20+1:KMAX_MID),&
                IIFULLDOM,JJFULLDOM,KMAX20,notfound)

    do k=1, KMAX_MID-KMAX20
       bc_rawdata(:,:,k)=bc_rawdata(:,:,KMAX_MID-KMAX20+1)
    enddo
    if(notfound)then
      call open_file(IO_GLOBBC,"r",fname,needed=.true.,skip=1)
      if ( ios /= 0 ) txtmsg = "BC Error O3"
      read(IO_GLOBBC,*) bc_rawdata
      close(IO_GLOBBC)
    endif
    if(DEBUG%GLOBBC)print *,"dsOH READ OZONE3 ",trim(fname),": ",&
      bc_rawdata(IIFULLDOM/2,JJFULLDOM/2,KMAX_MID)

    ! Mace Head adjustment: get mean ozone from Eastern sector
    O3fix=0.0
    icount=0
    if(USES%MACEHEADFIX)then
      do j=1,JJFULLDOM
        do i=1,IIFULLDOM
          if(glat_fdom(i,j)<macehead_lat+20.0.and.&
              glat_fdom(i,j)>macehead_lat-25.0.and.&
              glon_fdom(i,j)<macehead_lon     .and.&
              glon_fdom(i,j)>macehead_lon-40.0)then
              O3fix=O3fix+bc_rawdata(i,j,KMAX_MID)
              icount=icount+1
          endif
        enddo
      enddo
      if(icount>0) O3fix = O3fix/icount - macehead_O3(month)*PPB

      ! grid coordinates of Mace Head
      call lb2ij(macehead_lon,macehead_lat, iMH,jMH)

      if(DEBUG%GLOBBC) write(*,"(a,i4.2,2f7.2,i6,f8.3,a,4f8.3,2L3)")"O3FIXes ",&
        month,iMH,jMH, icount,bc_rawdata(nint(iMH),nint(jMH),20)/PPB,&
        " MH: ", macehead_default(month), macehead_O3(month),O3fix/PPB,&
        trend_O3, USES%MACEHEADFIX, USES%MACEHEAD_AVG
      write(*,"(a,f8.3)")' MaceHead correction for O3: ',-O3fix/PPB

    endif
    bc_rawdata = max(15.0*PPB,bc_rawdata-O3fix)
    bc_rawdata = bc_rawdata*trend_o3

  case ( IBC_H2O2 )

     bc_rawdata=1.0E-25

  case (IBC_NO  ,IBC_NO2  ,IBC_HNO3,IBC_CO, &
        IBC_C2H6,IBC_C4H10,IBC_PAN ,IBC_NO3_c)
    ! NB since we only call once per month we add 15 days to
    ! day-number to get a mid-month value
    cosfac = cos( twopi_yr * (daynumber+15.0-SpecBC(ibc)%dmax))
    bc_rawdata(:,:,KMAX_MID) = SpecBC(ibc)%surf + SpecBC(ibc)%amp*cosfac

    !/ - correct for other heights
    do k = 1, KMAX_MID-1
      scale_new = exp( -h_km(k)/SpecBC(ibc)%hz )
      bc_rawdata(:,:,k) = bc_rawdata(:,:,KMAX_MID)*scale_new
      if (DEBUG_HZ) then
        scale_old = exp( -(KMAX_MID-k)/SpecBC(ibc)%hz )
        write(*,"(a8,2i3,2f8.3,i4,f8.2,f8.3,2f8.3)") &
         "SCALE-HZ ", month, ibc, SpecBC(ibc)%surf, SpecBC(ibc)%hz, k,&
          h_km(k), p_kPa(k), scale_old, scale_new
      endif ! DEBUG_HZ
    enddo
    bc_rawdata = max( bc_rawdata, SpecBC(ibc)%vmin )

    !/ - correct for latitude functions
    forall(i=1:IIFULLDOM,j=1:JJFULLDOM)
      bc_rawdata(i,j,:) = bc_rawdata(i,j,:) * latfunc(ibc,lat5(i,j))
    endforall

    !/ trend adjustments
    if( ibc == IBC_C4H10 .or. ibc == IBC_C2H6 )then
      bc_rawdata =  bc_rawdata*trend_voc
    elseif( ibc == IBC_CO )then
      bc_rawdata =  bc_rawdata*trend_co
    endif

  case (IBC_SO2   , IBC_SO4  , IBC_HCHO , &
!        IBC_SEASALT_f,IBC_SEASALT_C, &
        IBC_CH3CHO, IBC_NH4_f, IBC_NO3_f)
    ! (No vertical variation for S in marine atmosphere, see W99)
    ! aNO3 and NH4 assumed to act as SO4
    !  and PAN is just temporary, with some guessing that
    !  since sources decrease with altitude, but lifetime
    !  increases the concs don't change much.
    cosfac = cos( twopi_yr * (daynumber+15.0-SpecBC(ibc)%dmax))
    bc_rawdata(:,:,:) =    SpecBC(ibc)%surf  + SpecBC(ibc)%amp*cosfac

  case (IBC_SEASALT_f, IBC_SEASALT_C, IBC_SEASALT_G)
    ! In BoundaryConditions, overland BICs will be reduced, but here
    ! we set the full 3-D array.
     cosfac = cos( twopi_yr * (daynumber+15.0-SpecBC(ibc)%dmax))
     bc_rawdata(:,:,:) =    SpecBC(ibc)%surf  + SpecBC(ibc)%amp*cosfac

    !/ - correct for latitude functions
    if (DEBUG_Logan) print *,"LOGAN HORIZ",ibc,SpecBC(ibc)%surf,cosfac
    do i = 1, IIFULLDOM
      do j = 1, JJFULLDOM
        bc_rawdata(i,j,:) = bc_rawdata(i,j,:) * latfunc(ibc,lat5(i,j))
        if ( DEBUG_Logan ) print "(2i4,f8.2,f15.4)",&
          j,lat5(i,j),latfunc(ibc,lat5(i,j)),bc_rawdata(36,j,1)
      enddo
    enddo

    case (IBC_DUST_c,IBC_dust_f)
      ! Dust: Sahara BIC from monthly 2000 data from CTM
      if (.not.DO_SAHARA) then
        bc_rawdata(:,:,:) = 0.0
      else
        print *, 'set bc_rawdata for DUST; used = ', used
        bc_rawdata(:,:,:) =    0.0

        ! set file name, either coarse or fine
        if (ibc == IBC_DUST_c) then
          fname=date2string("DUST_c_ext.MM",month=month)
        elseif (ibc == IBC_DUST_f) then
          fname=date2string("DUST_f_ext.MM",month=month)
        endif

        ! open the file
        call open_file(IO_GLOBBC,"r",fname,needed=.true.)
        if ( ios /= 0 ) txtmsg = "BC Error DUST"

        ! read the file ....
        do
          read(IO_GLOBBC,*,end=999) i, j, bc_rawdata(i,j,KMAX_MID)
        enddo
        999 continue
        close(IO_GLOBBC)

        !/ - correct for other heights
        ! the first 10 layers have about the same values
        do k=1,9
!fix          bc_rawdata(:,:,KMAX_MID-k) = bc_rawdata(:,:,KMAX_MID)
          bc_rawdata(:,:,KMAX_MID-k) = 0.5*bc_rawdata(:,:,KMAX_MID) ! ST
        enddo                 ! *0.5 as Mwt was changed from 100 to 200 g/mol
        ! remaining levers are about zero
        bc_rawdata(:,:,1:KMAX_MID-10) = 0.0
      endif

    case  default
      print *,"Error with specified BCs:", ibc
      txtmsg = "BC Error UNSPEC"
    end select
!================== end select ==================================

  if (DEBUG%GLOBBC) print *,"BCOH FACTOR ", ibc, fname
  call CheckStop(txtmsg)
  if (DEBUG_Logan) then
    print "(a15,3i4,f8.3)","DEBUG:LOGAN: ",ibc, used, month, cosfac
    print *,"LOGAN BC MAX ", maxval ( bc_rawdata ), &
                    " MIN ", minval ( bc_rawdata )
    do k = KMAX_MID, 1, -1        ! print out for equator, mid-lat
      print "(i4,f12.3)", k, bc_rawdata(15,15,k)
    enddo
  endif ! DEBUG


  !/ - correction for latitude functions
  bc_rawdata = max( bc_rawdata, SpecBC(ibc)%hmin )

  !/ trend adjustments
  select case (ibc)
  case(IBC_SO2,IBC_SO4)
    bc_rawdata = bc_rawdata*SIAtrend%so2
  case(IBC_NH4_f)
    bc_rawdata = bc_rawdata*SIAtrend%nh4
  case(IBC_NO3_f,IBC_NO3_c,IBC_HNO3,IBC_NO2,IBC_NO,IBC_PAN)
    bc_rawdata = bc_rawdata*SIAtrend%nox
  endselect


  if (DEBUG_Logan) print *,"LOGAN NEW MIN", minval ( bc_rawdata )


  if (used==1) then
    bc_rawdata = bc_rawdata * SpecBC(ibc)%conv_fac !Convert to mixing ratio
    j1 = 1
    do j = jglbeg,jglend
      i1 = 1
      do i = iglbeg,iglend
        bc_data(i1,j1,:) =  bc_rawdata(i,j,:)
        i1 = i1+1
      enddo
      j1 = j1+1
    enddo
  endif
end subroutine GetGlobalData

subroutine ReadBC_CDF(varname,month,bc_rawdata,varGIMAX,varGJMAX,varKMAX,notfound)
  logical, intent(out) :: notfound
  integer, intent(in) :: month
  integer, intent(in) :: varGIMAX,varGJMAX,varKMAX  ! dimensions of bc_rawdata
  real, dimension(*), intent(inout) :: bc_rawdata   ! NB written as one-dimensional
  character(len=*),intent(in) ::varname

  integer :: nstart,nfetch
  character(len=100) ::  filename
  character(len=*),parameter ::                     &
    REGIONAL='Boundary_and_Initial_Conditions.nc',  &
    GLOBAL='GLOBAL_O3.nc'

  nstart=month
  nfetch=1
  fileName=REGIONAL
  call GetCDF(varname,fileName,bc_rawdata,varGIMAX,varGJMAX,varKMAX,&
              nstart,nfetch,needed=.false.)
  notfound=(nfetch==0)
  if(notfound)then
    !interpolate from global file
    nstart=month
    nfetch=1
    fileName=GLOBAL
    call Read_Inter_CDF(fileName,varname,bc_rawdata,varGIMAX,varGJMAX,varKMAX,&
                        nstart,nfetch,interpol='bilinear',needed=.false.)
    notfound=(nfetch==0)
  endif
end subroutine ReadBC_CDF

end module GlobalBCs_ml
