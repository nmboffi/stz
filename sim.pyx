from fields cimport Field, update 
cimport numpy as np
from libc.stdlib cimport malloc, free
from libc.stdio cimport printf, sprintf, fprintf, fopen, fclose, FILE
cimport libc.math
from common cimport *
from update_fields cimport *
cimport mpi4py.libmpi as mpi

cpdef void go(int N_x, int N_y, int N_z, int N_t,                                # Number of grid points in each dimension 
         np.float64_t L_x, np.float64_t L_y, np.float64_t L_z,                   # Grid size in each dimension
         np.float64_t dx, np.float64_t dy, np.float64_t dz, np.float64_t dt,     # Time/spatial discretization
         np.float64_t mu, np.float64_t rho, np.float64_t lambd,                  # Material parameters
         np.float64_t t_0, np.float64_t t_f) nogil:                              # Initial and final time, list of time points

    """ Runs the simulation. Boundary conditions need to be put in EXPLICITLY in this file. 
    Grid is assumed to be of size nn_x x nn_y x nn_z on each process (total size is irrelevant to the calculations).
    The fourth dimension of the variable grid are all the parameters in the Field stored at grid[x, y, z].
    """

    cdef:
        int xx, yy, zz, t_ind
        int nn_x, nn_y, nn_z
        float tt
        Field *curr_grid_element
        Field *grid 
        FILE *fp
        np.float64_t [20] initial_field_values
        np.float64_t curr_sig_shear, curr_v_shear
        int [3] dims
        mpi.MPI_Comm comm
        int [1] rank
        int [1] size
        int [3] cc
        char *printbuf = <char *> malloc(50 * sizeof(char))
        char *allprint

    # Initialize MPI Cartesian communicator
    mpi.MPI_Comm_size(mpi.MPI_COMM_WORLD, size)
    get_dims(size[0], dims)
    mpi.MPI_Cart_create(mpi.MPI_COMM_WORLD, 3, dims, [1, 1, 1], 1, &comm)

    # Find our position in it
    mpi.MPI_Comm_rank(comm, rank)
    mpi.MPI_Cart_coords(comm, rank[0], 3, cc)

    if rank[0] == 0:
        allprint = <char *> malloc(size[0] * 50 * sizeof(char))
    else:
        allprint = NULL

    # Determine grid size per proc
    # Probably need to be more careful to ensure even division
    nn_x = N_x / dims[0]
    nn_y = N_y / dims[1]
    nn_z = N_z / dims[2]
    grid = <Field *> malloc((nn_x + 2) * (nn_y + 2) * (nn_z + 2) * sizeof(Field))

    # Initialize the values that every Field will start with.
    for xx in range(20):
        initial_field_values[xx] = 0

    # Set the output file
    fp = fopen("output.txt", "w")

    # Instantiate the grid
    for xx in range(nn_x + 2):
        for yy in range(nn_y + 2):
            for zz in range(nn_z + 2):
                set_val(grid, nn_x, nn_y, nn_z, xx, yy, zz, <Field *> initial_field_values)


    # Plug in any relevant boundary conditions (manually)
    set_boundary_conditions(grid, nn_x, nn_y, nn_z, dx,
                            L_x, L_y, L_z,
                            mu, rho)

    # Run the simulation
    for t_ind in range(N_t):

        # Update the ghost regions to enforce periodicity
        set_up_ghost_regions(grid, comm, cc[0], cc[1], cc[2], nn_x, nn_y, nn_z)

        # Current time
        tt = t_0 + dt * t_ind

        if (t_ind > 0):
            # First loop over the grid and calculate all changes
            for xx in range(1, nn_x + 1):
                for yy in range(1, nn_y + 1):
                    for zz in range(1, nn_z + 1):
                        # Calculate the changes in stress
                        update_stresses(grid, 
                                        xx, yy, zz,
                                        nn_x, nn_y, nn_z,
                                        dx, dy, dz,
                                        dt, lambd, mu) 

                        # Calculate the changes in velocities
                        update_velocities(grid,
                                          xx, yy, zz,
                                          nn_x, nn_y, nn_z,
                                          dx, dy, dz,
                                          dt, rho)

        # Now we have to loop again, because we can't add in the changes until
        # we have calculated the change for EVERY grid point (otherwise some grid points
        # will calculate the new values at timestep n+1 using other grid point values at timestep n+1)
        for xx in range(1, nn_x + 1):
            for yy in range(1, nn_y + 1):
                for zz in range(1, nn_z + 1):
                    # Note that the first update does nothing at the moment - this should be fixed later
                    curr_grid_element = look_up(grid, nn_x, nn_y, nn_z, xx, yy, zz)
                    update(curr_grid_element) 

                    if ((yy == 1) and (zz == 1)):
                        #printf("%d %f %d %f %d %f \n", xx, xx * dx, yy, yy * dy, zz, zz * dz)

                        # Calculate the value of the shear waves
                        # We use xx - 1 because xx = 1 corresponds to x = 0: xx=0 is the ghost region!
                        curr_sig_shear = shear_wave_sig((xx - 1) * dx, L_x, tt, mu, rho)
                        curr_v_shear = shear_wave_v((xx - 1) * dx, L_x, tt, mu, rho)

                        # And send the data to the root proc to print to output file
                        sprintf(printbuf, "%4.2f %4.2f %4.2f %4.2f %4.2f %4.2f %4.2f %4.2f %4.2f %4.2f\n",
                                # We again use xx-1, yy-1, and zz-1 by the above logic
                                tt, (xx-1)*dx, (yy-1)*dy, (zz-1)*dz,
                                curr_grid_element.v, curr_grid_element.s12,
                                curr_v_shear, curr_sig_shear,
                                libc.math.pow(libc.math.fabs(curr_grid_element.v - curr_v_shear), 2),
                                libc.math.pow(libc.math.fabs(curr_grid_element.s12 - curr_sig_shear), 2))
                        mpi.MPI_Gather(printbuf, 50, mpi.MPI_CHAR, allprint, 50 * size[0], mpi.MPI_CHAR, 0, comm)
                        if rank[0] == 0:
                            fprintf(fp, allprint)

    # And close the output file
    fclose(fp)

    free(printbuf)
    if rank[0] == 0:
        free(allprint)
    free(grid)
    
cdef void set_up_ghost_regions(Field *grid,                                   # Our grid for this process
                               mpi.MPI_Comm comm, int c_x, int c_y, int c_z,  # MPI cartesian communicator & our position in it
                               int nn_x, int nn_y, int nn_z) nogil:           # Number of non-ghost points in each dimension

    """ Sets the ghost regions as necessary. In the serial implementation, this is just simple 
    periodic boundary conditions. This function will become more complex when moving to the parallel implementation
    with MPI-based communcation across processors.
    """

    cdef:
        int xx, yy, zz
        int back, forward                                 # ranks of procs to send/recv ghost regions
        mpi.MPI_Datatype fieldtype
        mpi.MPI_Status status
        Field *buf_plane_z = <Field *> malloc((nn_x + 2) * (nn_y + 2) * sizeof(Field))

    mpi.MPI_Type_contiguous(20, mpi.MPI_FLOAT, &fieldtype)
    mpi.MPI_Type_commit(&fieldtype)

    # Instantiate periodic boundary conditions
    # First handle the z periodicity
    mpi.MPI_Cart_shift(comm, 2, 1, &back, &forward) 
    for xx in range(1, nn_x + 1):
        for yy in range(1, nn_y + 1):
            # We have 2 + nn_z points in the nn_z direction
            # zz = 0 corresponds to the "ghost plane" at the base
            # zz = nn_z + 1 corresponds to the "ghost plane" at the top
            # So we identify the ghost region at the base with the topmost "non-ghost" point
            # And the ghost region at the top with the bottommost "non-ghost" point
            
            # grid[xx, yy, 0] = grid[xx, yy, nn_z] of adjacent proc
            # copy values to send into buffer
            set_val(buf_plane_z, nn_x, 0, 0, xx, yy, 0,       look_up(grid, nn_x, nn_y, nn_z, xx, yy, nn_z))

    # send values & receive corresponding values from the other side
    mpi.MPI_Sendrecv_replace(buf_plane_z, nn_x * nn_y, fieldtype, forward, 2, back, 2, comm, &status)

    for xx in range(1, nn_x + 1):
        for yy in range(1, nn_y + 1):
            # copy received values into grid
            set_val(grid, nn_x, nn_y, nn_z, xx, yy, 0,        look_up(buf_plane_z, nn_x, 0, 0, xx, yy, 0))

            # grid[xx, yy, nn_z + 1] = grid[xx, yy, 1]
            # copy values to send into buffer
            set_val(buf_plane_z, nn_x, 0, 0, xx, yy, 0,       look_up(grid, nn_x, nn_y, nn_z, xx, yy, 1))

    # send values & receive corresponding values from the other side
    mpi.MPI_Sendrecv_replace(buf_plane_z, nn_x * nn_y, fieldtype, back, 2, forward, 2, comm, &status)

    for xx in range(1, nn_x + 1):
        for yy in range(1, nn_y + 1):
            # copy received values into grid
            set_val(grid, nn_x, nn_y, nn_z, xx, yy, nn_z + 1, look_up(buf_plane_z, nn_x, 0, 0, xx, yy, 0))

    free(buf_plane_z)

    cdef:
        Field *buf_plane_x = <Field *> malloc((nn_y + 2) * (nn_z + 2) * sizeof(Field))

    # Now do the same thing for the x periodicity
    mpi.MPI_Cart_shift(comm, 0, 1, &back, &forward)
    for yy in range(1, nn_y + 1):
        for zz in range(1, nn_z + 1):
            # See comments in the above loop for explanation

            # grid[0, yy, zz] = grid[nn_x, yy, zz]
            set_val(buf_plane_x, nn_y, 0, 0, yy, zz, 0,       look_up(grid, nn_x, nn_y, nn_z, nn_x, yy, zz))

    mpi.MPI_Sendrecv_replace(buf_plane_x, nn_y * nn_z, fieldtype, forward, 0, back, 0, comm, &status)

    for yy in range(1, nn_y + 1):
        for zz in range(1, nn_z + 1):
            set_val(grid, nn_x, nn_y, nn_z, 0, yy, zz,        look_up(buf_plane_x, nn_y, 0, 0, yy, zz, 0))

            # grid[nn_x + 1, yy, zz] = grid[1, yy, zz]
            set_val(buf_plane_x, nn_y, 0, 0, yy, zz, 0,       look_up(grid, nn_x, nn_y, nn_z, 1, yy, zz))

    mpi.MPI_Sendrecv_replace(buf_plane_x, nn_y * nn_z, fieldtype, back, 0, forward, 0, comm, &status)

    for yy in range(1, nn_y + 1):
        for zz in range(1, nn_z + 1):
            set_val(grid, nn_x, nn_y, nn_z, nn_x + 1, yy, zz, look_up(buf_plane_x, nn_y, 0, 0, yy, zz, 0))

    free(buf_plane_x)

    cdef:
        Field *buf_plane_y = <Field *> malloc((nn_x + 2) * (nn_z + 2) * sizeof(Field))

    # And finally the y periodicity
    mpi.MPI_Cart_shift(comm, 1, 1, &back, &forward)
    for xx in range(1, nn_x + 1):
        for zz in range(1, nn_z + 1):
            # See comments in the above loop for explanation
            # grid[xx, 0, zz] = grid[xx, nn_y, zz]
            set_val(buf_plane_y, nn_x, 0, 0, xx, zz, 0,       look_up(grid, nn_x, nn_y, nn_z, xx, nn_y, zz))

    mpi.MPI_Sendrecv_replace(buf_plane_y, nn_x * nn_z, fieldtype, forward, 1, back, 1, comm, &status)

    for xx in range(1, nn_x + 1):
        for zz in range(1, nn_z + 1):
            set_val(grid, nn_x, nn_y, nn_z, xx, 0, zz,        look_up(buf_plane_y, nn_x, 0, 0, xx, zz, 0))

            # grid[xx, nn_y + 1, zz] = grid[xx, 1, zz]
            set_val(buf_plane_y, nn_x, 0, 0, xx, zz, 0,       look_up(grid, nn_x, nn_y, nn_z, xx, 1, zz))

    mpi.MPI_Sendrecv_replace(buf_plane_y, nn_x * nn_z, fieldtype, back, 1, forward, 1, comm, &status)

    for xx in range(1, nn_x + 1):
        for zz in range(1, nn_z + 1):
            set_val(grid, nn_x, nn_y, nn_z, xx, nn_y + 1, zz, look_up(buf_plane_y, nn_x, 0, 0, xx, zz, 0))

    free(buf_plane_y)

    cdef:
        Field *buf_corner = <Field *> malloc(sizeof(Field))
        int tag = 0

    ## Now we need to handle the corner regions
    mpi.MPI_Cart_rank(comm, [c_x - 1, c_y - 1, c_z - 1], &back)
    mpi.MPI_Cart_rank(comm, [c_x + 1, c_y + 1, c_z + 1], &forward)
    set_val(buf_corner, 0, 0, 0, 0, 0, 0,                         look_up(grid, nn_x, nn_y, nn_z, nn_x, nn_y, nn_z))
    mpi.MPI_Sendrecv_replace(buf_corner, 1, fieldtype, forward, tag, back, tag, comm, &status)
    set_val(grid, nn_x, nn_y, nn_z, 0, 0, 0,                      buf_corner)
    set_val(buf_corner, 0, 0, 0, 0, 0, 0,                         look_up(grid, nn_x, nn_y, nn_z, 1, 1, 1))
    mpi.MPI_Sendrecv_replace(buf_corner, 1, fieldtype, back, tag, forward, tag, comm, &status)
    set_val(grid, nn_x, nn_y, nn_z, nn_x + 1, nn_y + 1, nn_z + 1, buf_corner)

    mpi.MPI_Cart_rank(comm, [c_x + 1, c_y - 1, c_z - 1], &back)
    mpi.MPI_Cart_rank(comm, [c_x - 1, c_y + 1, c_z + 1], &forward)
    set_val(buf_corner, 0, 0, 0, 0, 0, 0,                  look_up(grid, nn_x, nn_y, nn_z, 1, nn_y, nn_z))
    mpi.MPI_Sendrecv_replace(buf_corner, 1, fieldtype, forward, tag, back, tag, comm, &status)
    set_val(grid, nn_x, nn_y, nn_z, nn_x + 1, 0, 0,        buf_corner)
    set_val(buf_corner, 0, 0, 0, 0, 0, 0,                  look_up(grid, nn_x, nn_y, nn_z, nn_x, 1, 1))
    mpi.MPI_Sendrecv_replace(buf_corner, 1, fieldtype, back, tag, forward, tag, comm, &status)
    set_val(grid, nn_x, nn_y, nn_z, 0, nn_y + 1, nn_z + 1, buf_corner)

    mpi.MPI_Cart_rank(comm, [c_x - 1, c_y + 1, c_z - 1], &back)
    mpi.MPI_Cart_rank(comm, [c_x + 1, c_y - 1, c_z + 1], &forward)
    set_val(buf_corner, 0, 0, 0, 0, 0, 0,                  look_up(grid, nn_x, nn_y, nn_z, nn_x, 1, nn_z))
    mpi.MPI_Sendrecv_replace(buf_corner, 1, fieldtype, forward, tag, back, tag, comm, &status)
    set_val(grid, nn_x, nn_y, nn_z, 0, nn_y + 1, 0,        buf_corner)
    set_val(buf_corner, 0, 0, 0, 0, 0, 0,                  look_up(grid, nn_x, nn_y, nn_z, 1, nn_y, 1))
    mpi.MPI_Sendrecv_replace(buf_corner, 1, fieldtype, back, tag, forward, tag, comm, &status)
    set_val(grid, nn_x, nn_y, nn_z, nn_x + 1, 0, nn_z + 1, buf_corner)

    mpi.MPI_Cart_rank(comm, [c_x - 1, c_y - 1, c_z + 1], &back)
    mpi.MPI_Cart_rank(comm, [c_x + 1, c_y + 1, c_z - 1], &forward)
    set_val(buf_corner, 0, 0, 0, 0, 0, 0,                  look_up(grid, nn_x, nn_y, nn_z, nn_x, 1, nn_z))
    mpi.MPI_Sendrecv_replace(buf_corner, 1, fieldtype, forward, tag, back, tag, comm, &status)
    set_val(grid, nn_x, nn_y, nn_z, 0, nn_y + 1, 0,        buf_corner)
    set_val(buf_corner, 0, 0, 0, 0, 0, 0,                  look_up(grid, nn_x, nn_y, nn_z, 1, nn_y, 1))
    mpi.MPI_Sendrecv_replace(buf_corner, 1, fieldtype, back, tag, forward, tag, comm, &status)
    set_val(grid, nn_x, nn_y, nn_z, nn_x + 1, 0, nn_z + 1, buf_corner)

    free(buf_corner)

    cdef:
        Field *buf_line_xz = <Field *> malloc((nn_y + 2) * sizeof(Field))

    # And the "corner lines"
    # Get rank of proc in correct grid position
    mpi.MPI_Cart_rank(comm, [c_x - 1, c_y, c_z + 1], &back)
    mpi.MPI_Cart_rank(comm, [c_x - 1, c_y, c_z - 1], &forward)

    # Fill line buffer
    for yy in range(1, nn_y + 1):
        set_val(buf_line_xz, yy, 0, 0, 0, 0, 0,          look_up(grid, nn_x, nn_y, nn_z, nn_x, yy, 1))
    # Send & receive corner line
    mpi.MPI_Sendrecv_replace(buf_line_xz, nn_y, fieldtype, forward, tag, back, tag, comm, &status)
    # Copy values from buffer back into grid & repeat in opposite direction
    for yy in range(1, nn_y + 1):
        set_val(grid, nn_x, nn_y, nn_z, 0, yy, nn_z + 1, look_up(buf_line_xz, yy, 0, 0, 0, 0, 0))
        set_val(buf_line_xz, yy, 0, 0, 0, 0, 0,          look_up(grid, nn_x, nn_y, nn_z, nn_x, yy, nn_z))
    mpi.MPI_Sendrecv_replace(buf_line_xz, nn_y, fieldtype, back, tag, forward, tag, comm, &status)
    for yy in range(1, nn_y + 1):
        set_val(grid, nn_x, nn_y, nn_z, 0, yy, 0,        look_up(buf_line_xz, yy, 0, 0, 0, 0, 0))

    mpi.MPI_Cart_rank(comm, [c_x + 1, c_y, c_z + 1], &back)
    mpi.MPI_Cart_rank(comm, [c_x + 1, c_y, c_z - 1], &forward)
    for yy in range(1, nn_y + 1):
        set_val(buf_line_xz, yy, 0, 0, 0, 0, 0,                 look_up(grid, nn_x, nn_y, nn_z, 1, yy, 1))
    mpi.MPI_Sendrecv_replace(buf_line_xz, nn_y, fieldtype, forward, tag, back, tag, comm, &status)
    for yy in range(1, nn_y + 1):
        set_val(grid, nn_x, nn_y, nn_z, nn_x + 1, yy, nn_z + 1, look_up(buf_line_xz, yy, 0, 0, 0, 0, 0))
        set_val(buf_line_xz, yy, 0, 0, 0, 0, 0,                 look_up(grid, nn_x, nn_y, nn_z, 1, yy, nn_z))
    mpi.MPI_Sendrecv_replace(buf_line_xz, nn_y, fieldtype, back, tag, forward, tag, comm, &status)
    for yy in range(1, nn_y + 1):
        set_val(grid, nn_x, nn_y, nn_z, nn_x + 1, yy, 0,        look_up(buf_line_xz, yy, 0, 0, 0, 0, 0))

    free(buf_line_xz)


    cdef:
        Field *buf_line_yz = <Field *> malloc((nn_x + 2) * sizeof(Field))

    mpi.MPI_Cart_rank(comm, [c_x, c_y - 1, c_z + 1], &back)
    mpi.MPI_Cart_rank(comm, [c_x, c_y - 1, c_z - 1], &forward)
    for xx in range(1, nn_x + 1):
        set_val(buf_line_yz, xx, 0, 0, 0, 0, 0,          look_up(grid, nn_x, nn_y, nn_z, xx, nn_y, 1))
    mpi.MPI_Sendrecv_replace(buf_line_yz, nn_x, fieldtype, forward, tag, back, tag, comm, &status)
    for xx in range(1, nn_x + 1):
        set_val(grid, nn_x, nn_y, nn_z, xx, 0, nn_z + 1, look_up(buf_line_yz, xx, 0, 0, 0, 0, 0))
        set_val(buf_line_yz, xx, 0, 0, 0, 0, 0,          look_up(grid, nn_x, nn_y, nn_z, xx, nn_y, nn_z))
    mpi.MPI_Sendrecv_replace(buf_line_yz, nn_x, fieldtype, back, tag, forward, tag, comm, &status)
    for xx in range(1, nn_x + 1):
        set_val(grid, nn_x, nn_y, nn_z, xx, 0, 0,        look_up(buf_line_yz, xx, 0, 0, 0, 0, 0))

    mpi.MPI_Cart_rank(comm, [c_x, c_y + 1, c_z + 1], &back)
    mpi.MPI_Cart_rank(comm, [c_x, c_y + 1, c_z - 1], &forward)
    for xx in range(1, nn_x + 1):
        set_val(buf_line_yz, xx, 0, 0, 0, 0, 0,                 look_up(grid, nn_x, nn_y, nn_z, xx, 1, 1))
    mpi.MPI_Sendrecv_replace(buf_line_yz, nn_x, fieldtype, forward, tag, back, tag, comm, &status)
    for xx in range(1, nn_x + 1):
        set_val(grid, nn_x, nn_y, nn_z, xx, nn_y + 1, nn_z + 1, look_up(buf_line_yz, xx, 0, 0, 0, 0, 0))
        set_val(buf_line_yz, xx, 0, 0, 0, 0, 0,                 look_up(grid, nn_x, nn_y, nn_z, xx, 1, nn_z))
    mpi.MPI_Sendrecv_replace(buf_line_yz, nn_x, fieldtype, back, tag, forward, tag, comm, &status)
    for xx in range(1, nn_x + 1):
        set_val(grid, nn_x, nn_y, nn_z, xx, nn_y + 1, 0,        look_up(buf_line_yz, xx, 0, 0, 0, 0, 0))

    free(buf_line_yz)


    cdef:
        Field *buf_line_xy = <Field *> malloc((nn_z + 2) * sizeof(Field))

    mpi.MPI_Cart_rank(comm, [c_x + 1, c_y + 1, c_z], &back)
    mpi.MPI_Cart_rank(comm, [c_x + 1, c_y - 1, c_z], &forward)
    for zz in range(1, nn_z + 1):
        set_val(buf_line_xy, zz, 0, 0, 0, 0, 0,                 look_up(grid, nn_x, nn_y, nn_z, 1, 1, zz))
    mpi.MPI_Sendrecv_replace(buf_line_xy, nn_z, fieldtype, forward, tag, back, tag, comm, &status)
    for zz in range(1, nn_z + 1):
        set_val(grid, nn_x, nn_y, nn_z, nn_x + 1, nn_y + 1, zz, look_up(buf_line_xy, zz, 0, 0, 0, 0, 0))
        set_val(buf_line_xy, zz, 0, 0, 0, 0, 0,                 look_up(grid, nn_x, nn_y, nn_z, 1, nn_y, zz))
    mpi.MPI_Sendrecv_replace(buf_line_xy, nn_z, fieldtype, back, tag, forward, tag, comm, &status)
    for zz in range(1, nn_z + 1):
        set_val(grid, nn_x, nn_y, nn_z, nn_x + 1, 0, zz,        look_up(buf_line_xy, zz, 0, 0, 0, 0, 0))

    mpi.MPI_Cart_rank(comm, [c_x - 1, c_y + 1, c_z], &back)
    mpi.MPI_Cart_rank(comm, [c_x - 1, c_y - 1, c_z], &forward)
    for zz in range(1, nn_z + 1):
        set_val(buf_line_xy, zz, 0, 0, 0, 0, 0,          look_up(grid, nn_x, nn_y, nn_z, nn_x, 1, zz))
    mpi.MPI_Sendrecv_replace(buf_line_xy, nn_z, fieldtype, forward, tag, back, tag, comm, &status)
    for zz in range(1, nn_z + 1):
        set_val(grid, nn_x, nn_y, nn_z, 0, nn_y + 1, zz, look_up(buf_line_xy, zz, 0, 0, 0, 0, 0))
        set_val(buf_line_xy, zz, 0, 0, 0, 0, 0,          look_up(grid, nn_x, nn_y, nn_z, nn_x, nn_y, zz))
    mpi.MPI_Sendrecv_replace(buf_line_xy, nn_z, fieldtype, back, tag, forward, tag, comm, &status)
    for zz in range(1, nn_z + 1):
        set_val(grid, nn_x, nn_y, nn_z, 0, 0, zz,        look_up(buf_line_xy, zz, 0, 0, 0, 0, 0))

    free(buf_line_xy)

cdef void set_boundary_conditions(Field *grid,                                                  # Grid
                                  int nn_x, int nn_y, int nn_z,                                 # Number of grid points
                                  np.float64_t dx,                                              # Grid spacing
                                  np.float64_t L_x, np.float64_t L_y, np.float64_t L_z,         # Grid dimensions
                                  np.float64_t mu, np.float64_t rho) nogil:                     # Material density and mu

    """ Instantiates shear wave boundary/initial conditions """
    cdef:
        int xx, yy, zz                                        # Loop indices
        Field *curr_field

    for xx in range(1, nn_x + 1):
        for yy in range(1, nn_y + 1):
            for zz in range(1, nn_z + 1):
                curr_field = look_up(grid, nn_x, nn_y, nn_z, xx, yy, zz)
                curr_field.v = shear_wave_v((xx - 1) * dx, L_x, 0, mu, rho)
                curr_field.s12 = shear_wave_sig((xx - 1) * dx, L_x, 0, mu, rho)

cdef np.float64_t shear_wave_v(np.float64_t xx, np.float64_t L_x, np.float64_t tt,
                               np.float64_t mu, np.float64_t rho) nogil:

    """ Returns the value of a velocity shear wave located in plane x=xx at time tt """

    cdef np.float64_t pi = 3.14159265359
    cdef np.float64_t c_s = libc.math.sqrt(mu / rho)

    return libc.math.sin(2 * pi / (L_x) * (xx - c_s * tt))

cdef np.float64_t shear_wave_sig(np.float64_t xx, np.float64_t L_x, np.float64_t tt,
                                 np.float64_t mu, np.float64_t rho) nogil:

    """ Returns the value of a shear-stress shear wave located in plane x=xx at time tt """

    return -rho * libc.math.sqrt(mu / rho) * shear_wave_v(xx, L_x, tt, mu, rho)

cdef void get_dims(int size, int dims[]) nogil:
    '''
    Return integer dimensions in 3D closest to a cube. Assumes number of procs is a power of 2.
    '''

    cdef:
        int log2_size = <int>(libc.math.log(size) / libc.math.log(2))
        int side
        int pwr

    # If number of procs is cubic, make a cube
    if log2_size % 3 == 0:
        side = 2 ** (log2_size / 3)
        for i in range(3):
            dims[i] = side
    # otherwise, one side will be either one factor of two lower or higher than the other two sides
    elif log2_size % 3 == 1:
        pwr = log2_size / 3
        dims[0] = 2 ** (pwr + 1)
        dims[1] = 2 ** pwr
        dims[2] = 2 ** pwr
    else:
        pwr = log2_size / 3 + 1
        dims[0] = 2 ** pwr
        dims[1] = 2 ** pwr
        dims[2] = 2 ** (pwr - 1)


